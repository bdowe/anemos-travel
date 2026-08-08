package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// TEMPORARY flight-offers provider swap (see the FLIGHT_OFFERS_PROVIDER block
// in .env.sample). The prod Duffel token is test-mode while live access is
// pending, and Duffel test mode returns synthetic offers — fake carriers,
// times, and prices — so the /plan agent would feed travelers fiction. When
// FLIGHT_OFFERS_PROVIDER=serpapi, the OFFERS search (and only the offers
// search) goes to SerpApi's Google Flights API instead; airport autocomplete
// and IATA resolution stay on Duffel, whose reference data is real even with
// a test token. Unset env => Duffel, byte-identical to before this file
// existed. Flip back by unsetting FLIGHT_OFFERS_PROVIDER and restarting.
//
// While active: price alerts are paused (price_alert_checker.go), bag fees
// are unpriceable so carry_on/checked searches classify "unknown"
// (flight_baggage.go), check_flight_connectivity rides the swap too but with
// a tighter candidate clamp and a daily-quota headroom guard
// (plan_connectivity.go), and a failed search degrades to a Google Flights
// deep link instead of an error (plan_tool_registry.go).

const (
	// serpapiCurrency is requested from SerpApi and stamped on every offer.
	// SerpApi echoes the requested currency rather than reporting one per
	// offer, and the Flutter model requires a non-null currency.
	serpapiCurrency = "USD"

	// serpapiCacheTTL keeps repeat identical searches (model retries, the
	// screen's Retry button, re-asks within a chat) from burning quota.
	// Deliberately overrides the "offers are never cached" doctrine in
	// duffel_service.go — 15-minute-stale real prices beat fresh fake ones,
	// and the free tier is 250 searches/month.
	serpapiCacheTTL = 15 * time.Minute

	// serpapiDailyKey is the single dailyCounter key: the cap is per process,
	// not per caller — it protects the monthly quota, not fairness.
	serpapiDailyKey = "serpapi"

	defaultSerpapiSearchesPerDay = 50
)

// serpapiSearchesPerDay caps upstream SerpApi searches per UTC day (cache
// hits are free). Exhaustion surfaces as a search error, which the chat tool
// degrades to a Google Flights deep link.
func serpapiSearchesPerDay() int {
	return envInt("SERPAPI_SEARCHES_PER_DAY", defaultSerpapiSearchesPerDay)
}

// SerpapiFlightsService is the temporary Google Flights offers provider.
// Unlike the Duffel/transcription singletons, Active/Configured read the
// environment at CALL time (the abuse_caps.go knob pattern) so tests can
// t.Setenv without hitting the init-order trap documented in
// plan_connectivity_test.go; the struct holds only the HTTP client, the
// quota-guard state, and the BaseURL test seam.
type SerpapiFlightsService struct {
	BaseURL string
	Client  *http.Client

	offersCache *ttlCache[[]FlightOffer]
	daily       *dailyCounter
	calls       upstreamCallCounters
}

// NewSerpapiFlightsService builds the service. The boot-time prints exist so
// the temporary mode is impossible to miss in the api logs.
func NewSerpapiFlightsService() *SerpapiFlightsService {
	baseURL := os.Getenv("SERPAPI_BASE_URL")
	if baseURL == "" {
		baseURL = "https://serpapi.com"
	}
	s := &SerpapiFlightsService{
		BaseURL:     strings.TrimRight(baseURL, "/"),
		Client:      newUpstreamClient(60 * time.Second),
		offersCache: newTTLCache[[]FlightOffer](serpapiCacheTTL, 500),
		daily:       newDailyCounter(),
	}
	if s.Active() {
		if s.Configured() {
			fmt.Println("Flight offers provider: SerpApi Google Flights (TEMPORARY swap; price alerts paused)")
		} else {
			fmt.Println("Warning: FLIGHT_OFFERS_PROVIDER=serpapi but SERPAPI_API_KEY not set; flight search degrades to Google Flights links")
		}
	}
	return s
}

// Active reports whether the temporary provider swap is switched on.
func (s *SerpapiFlightsService) Active() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("FLIGHT_OFFERS_PROVIDER")), "serpapi")
}

// Configured reports whether the SerpApi key is present.
func (s *SerpapiFlightsService) Configured() bool {
	return os.Getenv("SERPAPI_API_KEY") != ""
}

// RemainingToday reports how many upstream searches are left under today's
// cap (cache hits are free and never count). Feeds the
// check_flight_connectivity headroom guard.
func (s *SerpapiFlightsService) RemainingToday() int {
	remaining := serpapiSearchesPerDay() - s.daily.count(serpapiDailyKey, time.Now())
	if remaining < 0 {
		return 0
	}
	return remaining
}

// flightOffersSearch is the single offers-search seam for the temporary
// provider swap: SerpApi Google Flights when FLIGHT_OFFERS_PROVIDER=serpapi,
// Duffel otherwise. Every offers caller rides it: searchFlightsWithBaggage for
// bookable searches, and check_flight_connectivity's per-leg fan-out (which
// adds its own candidate clamp and RemainingToday headroom guard — see
// plan_connectivity.go).
func flightOffersSearch(ctx context.Context, d *DuffelService, req FlightSearchRequest) ([]FlightOffer, error) {
	if serpapiFlights.Active() {
		return serpapiFlights.SearchFlightOffers(ctx, req)
	}
	return d.SearchFlightOffers(ctx, req)
}

// --- SerpApi response shape (only the fields the mapping needs) ---

type serpapiFlightsResponse struct {
	Error        string              `json:"error"`
	BestFlights  []serpapiFlightItem `json:"best_flights"`
	OtherFlights []serpapiFlightItem `json:"other_flights"`
}

type serpapiFlightItem struct {
	Flights       []serpapiSegment `json:"flights"`
	TotalDuration int              `json:"total_duration"` // minutes
	Price         float64          `json:"price"`          // int in practice; float tolerates both
}

type serpapiSegment struct {
	DepartureAirport serpapiAirportTime `json:"departure_airport"`
	ArrivalAirport   serpapiAirportTime `json:"arrival_airport"`
	Airline          string             `json:"airline"`
	FlightNumber     string             `json:"flight_number"` // "BA 591"
}

type serpapiAirportTime struct {
	ID   string `json:"id"`             // IATA code
	Time string `json:"time,omitempty"` // "2026-09-01 08:15" (airport-local wall time)
}

// SearchFlightOffers searches Google Flights via SerpApi and maps the result
// onto the FlightOffer shape, so ranking/dedup (flight_optimizer.go) and every
// consumer work unchanged. Round trips use phase-1 only (one HTTP call):
// SerpApi's phase-1 prices are already round-trip totals, matching the
// FlightOffer.Price contract, but return-leg detail would need a second call
// per offer — so ReturnSegments stays empty while the swap is active.
func (s *SerpapiFlightsService) SearchFlightOffers(ctx context.Context, req FlightSearchRequest) ([]FlightOffer, error) {
	if !s.Configured() {
		return nil, fmt.Errorf("SerpApi key not configured")
	}

	cacheKey := strings.Join([]string{
		strings.ToUpper(req.Origin), strings.ToUpper(req.Destination),
		req.DepartDate, req.ReturnDate,
		fmt.Sprint(req.Adults), fmt.Sprint(req.ChildAges),
		strings.ToLower(req.CabinClass),
	}, "|")
	if cached, ok := s.offersCache.get(cacheKey); ok {
		s.calls.cacheHits.Add(1)
		// Copy-on-hit: RankFlightOffers sorts and writes scores in place and
		// searchFlightsWithBaggage writes BaggageStatus on elements, so the
		// cached backing array must never be handed out twice.
		return append([]FlightOffer(nil), cached...), nil
	}

	if s.daily.incr(serpapiDailyKey, time.Now()) > serpapiSearchesPerDay() {
		return nil, fmt.Errorf("SerpApi daily search cap reached")
	}

	body, status, err := s.fetch(ctx, req)
	if err != nil {
		return nil, err
	}

	var parsed serpapiFlightsResponse
	if jsonErr := json.Unmarshal(body, &parsed); jsonErr != nil && status >= 200 && status < 300 {
		return nil, fmt.Errorf("failed to parse SerpApi response: %w", jsonErr)
	}
	items := append(append([]serpapiFlightItem(nil), parsed.BestFlights...), parsed.OtherFlights...)
	// SerpApi signals a legitimately empty route with an error field (over
	// HTTP 400), e.g. "Google Flights hasn't returned any results for this
	// query." — that is "no flights", not an outage.
	legitimatelyEmpty := len(items) == 0 && strings.Contains(strings.ToLower(parsed.Error), "any results")
	if !legitimatelyEmpty && (status < 200 || status >= 300) {
		return nil, fmt.Errorf("SerpApi error (%d): %s", status, truncateForLog(body))
	}

	offers := make([]FlightOffer, 0, len(items))
	for i, item := range items {
		if len(offers) >= maxOffers {
			break
		}
		// A missing price would map to 0 and rank as the cheapest offer; an
		// itinerary with no segments renders as "→" in the details sheet.
		// Skip malformed items rather than surfacing them.
		if item.Price <= 0 || len(item.Flights) == 0 {
			continue
		}
		offers = append(offers, serpapiOffer(item, req, i))
	}

	// Empty results are cached too: a no-flights route retried by the flight
	// screen's Retry button or a re-asking model must not burn a daily-cap
	// slot and an upstream search on every repeat.
	s.offersCache.set(cacheKey, append([]FlightOffer(nil), offers...))
	return offers, nil
}

// fetch performs the HTTP round trip and returns the raw body + status. The
// API key travels as a QUERY PARAMETER, so transport errors (whose *url.Error
// embeds the full request URL) are redacted before entering the error chain —
// same hazard and same fix as the Google Places key (places_service.go).
// Callers must never log or echo the request URL.
func (s *SerpapiFlightsService) fetch(ctx context.Context, req FlightSearchRequest) ([]byte, int, error) {
	params := url.Values{}
	params.Set("engine", "google_flights")
	params.Set("api_key", os.Getenv("SERPAPI_API_KEY"))
	params.Set("departure_id", strings.ToUpper(strings.TrimSpace(req.Origin)))
	params.Set("arrival_id", strings.ToUpper(strings.TrimSpace(req.Destination)))
	params.Set("outbound_date", req.DepartDate)
	if req.ReturnDate != "" {
		params.Set("type", "1") // round trip, phase-1 only (prices are RT totals)
		params.Set("return_date", req.ReturnDate)
	} else {
		params.Set("type", "2") // one way
	}
	params.Set("currency", serpapiCurrency)

	adults := req.Adults
	if adults < 1 {
		adults = 1
	}
	children, infants := 0, 0
	for _, age := range req.ChildAges {
		switch {
		case age >= 12: // Google Flights counts 12+ as adults
			adults++
		case age >= 2:
			children++
		default:
			infants++
		}
	}
	params.Set("adults", fmt.Sprint(adults))
	if children > 0 {
		params.Set("children", fmt.Sprint(children))
	}
	if infants > 0 {
		params.Set("infants_on_lap", fmt.Sprint(infants))
	}
	if class := serpapiTravelClass(req.CabinClass); class != "1" {
		params.Set("travel_class", class)
	}
	// No deep_search (seconds slower for marginal accuracy) and no sort_by —
	// RankFlightOffers re-ranks on optimize_for regardless.

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, s.BaseURL+"/search?"+params.Encode(), nil)
	if err != nil {
		// A malformed BaseURL fails as *url.Error{Op:"parse"} whose message
		// quotes the ENTIRE raw URL, api_key included — redact like Do errors.
		return nil, 0, fmt.Errorf("failed to build request: %w", redactTransportError(err))
	}
	httpReq.Header.Set("Accept", "application/json")

	s.calls.upstream.Add(1)
	resp, err := s.Client.Do(httpReq)
	if err != nil {
		return nil, 0, fmt.Errorf("SerpApi request failed: %w", redactTransportError(err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, 0, fmt.Errorf("failed to read SerpApi response: %w", err)
	}
	return body, resp.StatusCode, nil
}

// serpapiTravelClass maps our cabin_class values onto SerpApi's 1-4 enum.
func serpapiTravelClass(cabin string) string {
	switch strings.ToLower(strings.TrimSpace(cabin)) {
	case "premium_economy":
		return "2"
	case "business":
		return "3"
	case "first":
		return "4"
	default:
		return "1" // economy / empty / unknown
	}
}

// serpapiOffer maps one SerpApi itinerary onto FlightOffer. Score fields stay
// zero (RankFlightOffers fills them); baggage fields stay zero/empty — SerpApi
// has no allowance or bag-fee data, so carry_on/checked searches classify
// every offer "unknown" and summarizeOffers already warns the model.
func serpapiOffer(item serpapiFlightItem, req FlightSearchRequest, idx int) FlightOffer {
	legs := make([]FlightLeg, 0, len(item.Flights))
	airlines := make([]string, 0, 2)
	seen := map[string]bool{}
	for _, seg := range item.Flights {
		legs = append(legs, FlightLeg{
			From:         seg.DepartureAirport.ID,
			To:           seg.ArrivalAirport.ID,
			Carrier:      seg.Airline,
			FlightNumber: strings.ReplaceAll(seg.FlightNumber, " ", ""),
			DepartTime:   serpapiTimeToISO(seg.DepartureAirport.Time),
			ArriveTime:   serpapiTimeToISO(seg.ArrivalAirport.Time),
		})
		if seg.Airline != "" && !seen[seg.Airline] {
			seen[seg.Airline] = true
			airlines = append(airlines, seg.Airline)
		}
	}

	return FlightOffer{
		// Synthetic ID: unique within one response, which is all consumers
		// need (best_offer_id match, Flutter list keys, savings label). Never
		// persisted — price alerts are paused while the swap is active.
		ID:       fmt.Sprintf("serpapi:%s-%s:%s:%d", strings.ToUpper(req.Origin), strings.ToUpper(req.Destination), req.DepartDate, idx),
		Price:    item.Price, // round-trip TOTAL on type=1 (phase-1 semantics)
		Currency: serpapiCurrency,
		Stops:    len(item.Flights) - 1,
		// Outbound-based, like Duffel round trips (duffel_service.go): SerpApi
		// phase-1 total_duration covers the outbound slice only.
		DurationMin: item.TotalDuration,
		Airlines:    airlines,
		AirlineCode: serpapiAirlineCode(item.Flights[0].FlightNumber),
		// AirlineLogoURL stays empty: SerpApi serves PNG logos and the Flutter
		// AirlineLogo widget renders SvgPicture.network; empty is the clean
		// already-handled no-logo state.
		DepartTime: legs[0].DepartTime,
		ArriveTime: legs[len(legs)-1].ArriveTime,
		Segments:   legs,
		// BookingURL left empty — both callers run attachBookingURLs, and with
		// an unknown AirlineCode that lands on the Google Flights deep link.
	}
}

// serpapiAirlineCode extracts the carrier IATA code from a "BA 591"-style
// flight number: the token before the first space, accepted only when it
// looks like a 2-3 char airline code. Empty on anything else — a missing code
// just routes attachBookingURLs to the Google Flights fallback link.
func serpapiAirlineCode(flightNumber string) string {
	code, _, ok := strings.Cut(strings.TrimSpace(flightNumber), " ")
	if !ok || len(code) < 2 || len(code) > 3 {
		return ""
	}
	for _, r := range code {
		isDigit := r >= '0' && r <= '9'
		isUpper := r >= 'A' && r <= 'Z'
		isLower := r >= 'a' && r <= 'z'
		if !isDigit && !isUpper && !isLower {
			return ""
		}
	}
	return strings.ToUpper(code)
}

// serpapiTimeToISO converts SerpApi's "2026-09-01 08:15" (airport-local wall
// time, no zone — the same zoneless convention Duffel emits) to the
// "2026-09-01T08:15:00" shape the Flutter clock labels and the dedup
// scheduleSignature expect. On anything unparseable, fall back to swapping
// the separator so the required-non-null field is never empty.
func serpapiTimeToISO(t string) string {
	if parsed, err := time.Parse("2006-01-02 15:04", t); err == nil {
		return parsed.Format("2006-01-02T15:04:05")
	}
	return strings.Replace(t, " ", "T", 1)
}

// serpapiFlights is the process-wide singleton, matching the Duffel /
// Ticketmaster / transcription convention. Behavior still keys off call-time
// env reads (Active/Configured); only the client, cache, and counters live here.
var serpapiFlights = NewSerpapiFlightsService()
