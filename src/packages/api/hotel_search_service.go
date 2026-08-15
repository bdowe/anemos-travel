package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Lodging lookup for the /plan agent's search_hotels tool and GET
// /hotels/search (specs/hotel-search). Two tiers behind ONE result type:
//
//   - RATES tier — SerpApi's Google Hotels engine. Real properties with real
//     nightly/total rates for the traveler's real dates.
//   - DISCOVERY tier — Google Places `type=lodging` (SearchLodging). Real,
//     well-rated properties with NO rates.
//
// The split is the shape of the data, not a preference: the rates engine
// REQUIRES check_in_date (a dateless call is rejected upstream), and Google
// does not price lodging at all — `price_level` comes back null on every
// hotel. So neither tier can answer the other's question, and the discovery
// tier is what keeps the tool useful when dates are unknown, the day's
// allowance is spent, or the rates provider is down.
//
// HotelSearchResult.RatesLive says WHICH question was answered. It is carried
// explicitly rather than inferred from "does a stay have a price", because a
// rates-tier result with one priceless property would otherwise mislabel the
// whole set — and the summarizer uses this flag to tell the model, in words,
// not to invent a price it was never given.
//
// NOT the temporary flights swap. search_hotels shares SERPAPI_API_KEY with
// serpapi_flights_service.go but nothing else: no FLIGHT_OFFERS_PROVIDER
// gate, its own daily counter, its own cache, its own naming. The flights
// seam is scheduled for deletion by `grep serpapiFlights` when the Duffel
// live token lands; this feature is permanent and must not be swept up in it.
// (It also inherits the whole monthly allowance when that happens.)

const (
	// hotelRatesCacheTTL is deliberately far longer than the flights cache's
	// 15 minutes. A city+dates rate set is re-asked constantly within one
	// planning session ("what about cheaper?", "show me those again") and
	// moves far more slowly than an airfare, so a stale-by-hours rate is a
	// good trade against a 250/month allowance.
	hotelRatesCacheTTL = 6 * time.Hour

	// hotelRatesDailyKey is this feature's OWN counter key. Sharing the
	// flights key would let one hotel-heavy session starve search_flights,
	// which is the failure the separate cap exists to prevent.
	hotelRatesDailyKey = "hotels"

	// 250/month free tier ÷ 31 days ≈ 8. A daily cap does not by itself
	// protect a MONTHLY quota (8×31 = 248 only just fits, and flights spend
	// from the same 250), so the 6h cache is the real lever and this is the
	// backstop that keeps one bad day from eating the month.
	defaultHotelSearchesPerDay = 8

	// hotelResultCap bounds what the model and the card rail ever see. The
	// upstream returns ~20; the rail caps at 8 (planPlacesCardCap) and a long
	// numbered list is pure token cost for a decision made from the top few.
	hotelResultCap = 10

	// defaultHotelCurrency is REQUESTED from the provider and stamped on each
	// stay. The provider echoes the requested currency rather than reporting
	// one per property — same convention as serpapiCurrency for flights.
	defaultHotelCurrency = "USD"
)

// hotelSearchesPerDay caps upstream rate lookups per UTC day (cache hits are
// free). Exhaustion is not an error: it degrades to the discovery tier.
//
// DIVERGES from envInt deliberately, and the divergence is the whole point:
// envInt falls back on any non-POSITIVE value, so `=0` would silently mean
// "use the default 8" — the opposite of what an operator who typed zero
// meant. Here an explicitly-set 0 means zero: rate lookups off, discovery
// only. That is the one knob that turns this feature's upstream spend off
// without unsetting the shared SERPAPI_API_KEY (which flights also needs),
// so it has to mean what it says. Only an unset or unparseable value falls
// back, and a negative one is clamped to 0 rather than treated as absent.
func hotelSearchesPerDay() int {
	raw, ok := os.LookupEnv("SERPAPI_HOTEL_SEARCHES_PER_DAY")
	if !ok || strings.TrimSpace(raw) == "" {
		return defaultHotelSearchesPerDay
	}
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return defaultHotelSearchesPerDay
	}
	if n < 0 {
		return 0
	}
	return n
}

// hotelRatesCurrency is the currency asked of the provider. Single knob: this
// app has no FX anywhere, so a result set is priced in exactly one currency.
func hotelRatesCurrency() string {
	if c := strings.ToUpper(strings.TrimSpace(os.Getenv("HOTEL_RATES_CURRENCY"))); len(c) == 3 {
		return c
	}
	return defaultHotelCurrency
}

// HotelStay is one property, in the ONE shape both tiers produce. A tier that
// produced a different shape would force every consumer — dispatcher,
// summarizer, SSE payload, Flutter card — to branch on provider, which is two
// definitions of "a stay" (docs/zen.md: one obvious way to do it).
type HotelStay struct {
	Name string `json:"name"`
	// Kind is "hotel" or "vacation_rental" — the provider mixes both and they
	// are not interchangeable to a traveler deciding where to sleep.
	Kind      string   `json:"kind"`
	StarClass *int     `json:"star_class,omitempty"`
	Rating    *float64 `json:"rating,omitempty"`
	Reviews   *int     `json:"reviews,omitempty"`

	// RatePerNight/TotalRate/Currency are a both-or-neither group. A number
	// with no currency is a number nobody can compare, and there is no FX in
	// this app by design (migration 00042, 00061, 00065 all say the same).
	// All three are absent together on the discovery tier.
	RatePerNight *float64 `json:"rate_per_night,omitempty"`
	TotalRate    *float64 `json:"total_rate,omitempty"`
	Currency     *string  `json:"currency,omitempty"`

	Latitude  *float64 `json:"latitude,omitempty"`
	Longitude *float64 `json:"longitude,omitempty"`
	Address   string   `json:"address,omitempty"`

	// Exactly ONE of ImageURL / PhotoRef is set, because the two tiers hand
	// back genuinely different kinds of image handle and the server cannot
	// collapse them: ImageURL is an absolute googleusercontent URL the client
	// loads directly (CORS-open, not a billed Place Photo), while PhotoRef is
	// a Google reference that must be exchanged through OUR /places/photo
	// gate — and only the client knows its own API base URL, so only the
	// client can build that link (utils/place_links.dart). The Dart model
	// exposes one accessor over both so the card never has to care.
	ImageURL     string   `json:"image_url,omitempty"`
	PhotoRef     string   `json:"photo_ref,omitempty"`
	BookingURL   string   `json:"booking_url"`
	Amenities    []string `json:"amenities,omitempty"`
	CheckInTime  string   `json:"check_in_time,omitempty"`
	CheckOutTime string   `json:"check_out_time,omitempty"`
}

// HotelSearchRequest is one lodging lookup. CheckIn/CheckOut are optional but
// paired — validated by the caller, since "one date" cannot mean anything.
type HotelSearchRequest struct {
	City      string
	CheckIn   string // YYYY-MM-DD
	CheckOut  string // YYYY-MM-DD
	Adults    int
	MaxPrice  int     // per night, in the result currency; 0 = no ceiling
	MinRating float64 // 0 = no floor
}

// HotelSearchResult is the result SET. RatesLive belongs here and not on a
// stay: it describes which question the search answered, which is a property
// of the lookup, not of any one property in it.
type HotelSearchResult struct {
	City     string      `json:"city"`
	CheckIn  string      `json:"check_in,omitempty"`
	CheckOut string      `json:"check_out,omitempty"`
	Stays    []HotelStay `json:"stays"`
	// Adults the rates are for. Carried because a nightly rate is meaningless
	// without the party it covers — the exact shape of the flight-price bug
	// this repo already paid for, where unlabeled party/round-trip totals read
	// as per-person fares. The summarizer states it in the same breath as the
	// number.
	Adults    int  `json:"adults,omitempty"`
	RatesLive bool `json:"rates_live"`
	// RatesNote is a stable code explaining a false RatesLive, so the client
	// can localize it and the summarizer can say something true:
	// "no_dates" | "quota" | "unavailable" | "not_configured".
	RatesNote string `json:"rates_note,omitempty"`
}

// SerpapiHotelsService is the rates tier. Like the flights service, Configured
// is a CALL-TIME env read (t.Setenv cannot reach an init-time singleton — see
// plan_connectivity_test.go); the struct holds only the client, cache, quota
// state and the BaseURL test seam.
type SerpapiHotelsService struct {
	BaseURL string
	Client  *http.Client

	cache *ttlCache[[]HotelStay]
	daily *dailyCounter
	calls upstreamCallCounters
}

func NewSerpapiHotelsService() *SerpapiHotelsService {
	baseURL := os.Getenv("SERPAPI_BASE_URL")
	if baseURL == "" {
		baseURL = "https://serpapi.com"
	}
	return &SerpapiHotelsService{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Client:  newUpstreamClient(30 * time.Second),
		cache:   newTTLCache[[]HotelStay](hotelRatesCacheTTL, 300),
		daily:   newDailyCounter(),
	}
}

// Configured reports whether the rates tier can run at all.
func (s *SerpapiHotelsService) Configured() bool {
	return os.Getenv("SERPAPI_API_KEY") != ""
}

// RemainingToday is how many upstream rate lookups are left under today's cap.
// Cache hits are free and never count.
func (s *SerpapiHotelsService) RemainingToday() int {
	remaining := hotelSearchesPerDay() - s.daily.count(hotelRatesDailyKey, time.Now())
	if remaining < 0 {
		return 0
	}
	return remaining
}

// searchHotels is the single entry point for both tiers, and the one place
// that decides which answered. Never returns an error for a provider problem:
// a failed rates lookup degrades to discovery, because a traveler asking
// where to stay is better served by real well-rated properties than by an
// apology (the same doctrine as search_flights' deep-link degrade, with a
// better floor).
func searchHotels(ctx context.Context, req HotelSearchRequest) (HotelSearchResult, error) {
	adults := req.Adults
	if adults < 1 {
		adults = 2
	}
	req.Adults = adults
	res := HotelSearchResult{City: req.City, CheckIn: req.CheckIn, CheckOut: req.CheckOut, Adults: adults}

	switch {
	case req.CheckIn == "" || req.CheckOut == "":
		// The rates engine rejects a dateless query outright, so this is not
		// worth an upstream call to discover.
		res.RatesNote = "no_dates"
	case !serpapiHotels.Configured():
		res.RatesNote = "not_configured"
	case serpapiHotels.RemainingToday() <= 0:
		res.RatesNote = "quota"
	default:
		stays, err := serpapiHotels.SearchStays(ctx, req)
		if err != nil {
			fmt.Printf("hotel rates lookup failed for %q, falling back to lodging discovery: %v\n", req.City, err)
			res.RatesNote = "unavailable"
			break
		}
		res.Stays = stays
		res.RatesLive = true
		return res, nil
	}

	stays, err := discoverLodging(ctx, req)
	if err != nil {
		return res, err
	}
	res.Stays = stays
	return res, nil
}

// discoverLodging is the no-rates tier: Google Places lodging results mapped
// into the same HotelStay shape, with the price group left entirely absent.
// Google's own price_level is deliberately NOT mapped onto anything — it is
// null for lodging in practice, and a $-sign is not a rate.
func discoverLodging(ctx context.Context, req HotelSearchRequest) ([]HotelStay, error) {
	places, err := placesService.SearchLodging(ctx, "hotels in "+req.City)
	if err != nil {
		return nil, err
	}

	stays := make([]HotelStay, 0, len(places))
	for _, p := range places {
		if len(stays) >= hotelResultCap {
			break
		}
		if req.MinRating > 0 && (p.Rating == nil || *p.Rating < req.MinRating) {
			continue
		}
		lat, lng := p.Latitude, p.Longitude
		stay := HotelStay{
			Name:      p.Name,
			Kind:      "hotel",
			Rating:    p.Rating,
			Reviews:   p.UserRatingsTotal,
			Latitude:  &lat,
			Longitude: &lng,
			Address:   p.Address,
			// Booking handoff uses OUR affiliate builder, not a provider link:
			// bookingProvider carries BOOKING_AFFILIATE_ID and is the only
			// lodging handoff that earns anything (docs/business-model.md).
			BookingURL: bookingProvider{}.SearchURL(AccommodationQuery{
				Destination: p.Name + " " + req.City,
				CheckIn:     req.CheckIn,
				CheckOut:    req.CheckOut,
				Guests:      req.Adults,
			}),
		}
		if p.PhotoRef != "" {
			// Register at emit time, exactly like placeCards: the gate must
			// cover what a client was actually shown, cache-served or not.
			stay.PhotoRef = p.PhotoRef
			placesService.allowPhotoRef(p.PhotoRef)
		}
		stays = append(stays, stay)
	}
	return stays, nil
}

// --- SerpApi Google Hotels response shape (only the fields we map) ---

type serpapiHotelsResponse struct {
	Error      string                `json:"error"`
	Properties []serpapiHotelProdRaw `json:"properties"`
}

type serpapiHotelProdRaw struct {
	Name                string `json:"name"`
	Type                string `json:"type"`
	Link                string `json:"link"`
	ExtractedHotelClass *int   `json:"extracted_hotel_class"`
	OverallRating       *float64
	Reviews             *int `json:"reviews"`
	GPSCoordinates      *struct {
		Latitude  float64 `json:"latitude"`
		Longitude float64 `json:"longitude"`
	} `json:"gps_coordinates"`
	RatePerNight *serpapiHotelRate `json:"rate_per_night"`
	TotalRate    *serpapiHotelRate `json:"total_rate"`
	Amenities    []string          `json:"amenities"`
	CheckInTime  string            `json:"check_in_time"`
	CheckOutTime string            `json:"check_out_time"`
	Images       []struct {
		Thumbnail string `json:"thumbnail"`
	} `json:"images"`
}

// UnmarshalJSON exists only because overall_rating arrives as a float with
// noisy precision (4.6833334) that we round once, at the boundary, rather
// than in every renderer.
func (p *serpapiHotelProdRaw) UnmarshalJSON(b []byte) error {
	type alias serpapiHotelProdRaw
	var tmp struct {
		alias
		OverallRating *float64 `json:"overall_rating"`
	}
	if err := json.Unmarshal(b, &tmp); err != nil {
		return err
	}
	*p = serpapiHotelProdRaw(tmp.alias)
	if tmp.OverallRating != nil {
		rounded := float64(int(*tmp.OverallRating*10+0.5)) / 10
		p.OverallRating = &rounded
	}
	return nil
}

type serpapiHotelRate struct {
	ExtractedLowest *float64 `json:"extracted_lowest"`
}

// SearchStays performs one rates lookup, honouring the cache and the daily
// cap. Errors here are never fatal to the caller — searchHotels degrades.
func (s *SerpapiHotelsService) SearchStays(ctx context.Context, req HotelSearchRequest) ([]HotelStay, error) {
	currency := hotelRatesCurrency()
	cacheKey := strings.Join([]string{
		strings.ToLower(strings.TrimSpace(req.City)), req.CheckIn, req.CheckOut,
		strconv.Itoa(req.Adults), strconv.Itoa(req.MaxPrice),
		strconv.FormatFloat(req.MinRating, 'f', 1, 64), currency,
	}, "|")

	if cached, ok := s.cache.get(cacheKey); ok {
		s.calls.cacheHits.Add(1)
		return append([]HotelStay(nil), cached...), nil
	}

	if s.daily.incr(hotelRatesDailyKey, time.Now()) > hotelSearchesPerDay() {
		return nil, fmt.Errorf("hotel search daily cap reached")
	}

	body, status, err := s.fetch(ctx, req, currency)
	if err != nil {
		return nil, err
	}

	var parsed serpapiHotelsResponse
	if jsonErr := json.Unmarshal(body, &parsed); jsonErr != nil && status >= 200 && status < 300 {
		return nil, fmt.Errorf("failed to parse SerpApi hotels response: %w", jsonErr)
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("SerpApi hotels error (%d): %s", status, truncateForLog(body))
	}

	stays := make([]HotelStay, 0, len(parsed.Properties))
	for _, p := range parsed.Properties {
		if len(stays) >= hotelResultCap {
			break
		}
		if stay, ok := hotelStayFromSerpapi(p, req, currency); ok {
			stays = append(stays, stay)
		}
	}

	// DIVERGENCE from serpapi_flights_service.go, which caches empty results
	// on purpose. An empty ROUTE is a real answer ("nobody flies that"); an
	// empty CITY is not — every city has hotels, so zero properties means a
	// city string the provider did not recognise or an upstream hiccup.
	// Caching that for six hours would poison the city for the rest of the
	// session, and a retry costs one search against a cap that exists to be
	// spent on real answers.
	if len(stays) > 0 {
		s.cache.set(cacheKey, append([]HotelStay(nil), stays...))
	}
	return stays, nil
}

// hotelStayFromSerpapi maps one property. Returns false for anything we would
// render dishonestly: no name, or a rates-tier row with no rate (the tier's
// whole promise is a price, and a blank price beside priced neighbours reads
// as "free").
func hotelStayFromSerpapi(p serpapiHotelProdRaw, req HotelSearchRequest, currency string) (HotelStay, bool) {
	if strings.TrimSpace(p.Name) == "" {
		return HotelStay{}, false
	}
	if p.RatePerNight == nil || p.RatePerNight.ExtractedLowest == nil {
		return HotelStay{}, false
	}
	nightly := *p.RatePerNight.ExtractedLowest
	if nightly <= 0 {
		return HotelStay{}, false
	}
	if req.MaxPrice > 0 && nightly > float64(req.MaxPrice) {
		return HotelStay{}, false
	}
	if req.MinRating > 0 && (p.OverallRating == nil || *p.OverallRating < req.MinRating) {
		return HotelStay{}, false
	}

	cur := currency
	stay := HotelStay{
		Name:         p.Name,
		Kind:         hotelKind(p.Type),
		StarClass:    p.ExtractedHotelClass,
		Rating:       p.OverallRating,
		Reviews:      p.Reviews,
		RatePerNight: &nightly,
		Currency:     &cur,
		Amenities:    p.Amenities,
		CheckInTime:  p.CheckInTime,
		CheckOutTime: p.CheckOutTime,
		// p.Link is the property's OWN website, which earns nothing. The
		// monetized handoff is our Booking.com builder with the affiliate id.
		BookingURL: bookingProvider{}.SearchURL(AccommodationQuery{
			Destination: p.Name + " " + req.City,
			CheckIn:     req.CheckIn,
			CheckOut:    req.CheckOut,
			Guests:      req.Adults,
		}),
	}
	if p.TotalRate != nil && p.TotalRate.ExtractedLowest != nil && *p.TotalRate.ExtractedLowest > 0 {
		total := *p.TotalRate.ExtractedLowest
		stay.TotalRate = &total
	}
	if p.GPSCoordinates != nil {
		lat, lng := p.GPSCoordinates.Latitude, p.GPSCoordinates.Longitude
		stay.Latitude, stay.Longitude = &lat, &lng
	}
	if len(p.Images) > 0 {
		// Thumbnails are lh3-lh6.googleusercontent.com with
		// `access-control-allow-origin: *`, so Flutter web loads them
		// directly. They are NOT Google Place Photo refs, so they neither
		// need nor may use the /places/photo billing gate.
		stay.ImageURL = p.Images[0].Thumbnail
	}
	return stay, true
}

// hotelKind normalizes the provider's free-text type onto our two values.
func hotelKind(t string) string {
	if strings.Contains(strings.ToLower(t), "vacation") {
		return "vacation_rental"
	}
	return "hotel"
}

// fetch performs the HTTP round trip. The API key travels as a QUERY
// PARAMETER, so transport errors (whose *url.Error embeds the full request
// URL) are redacted on BOTH the build and Do paths — the build-path leak was
// a real review finding on the flights seam, where a malformed base URL would
// have sent the key to Sentry. Callers must never log or echo the URL.
func (s *SerpapiHotelsService) fetch(ctx context.Context, req HotelSearchRequest, currency string) ([]byte, int, error) {
	adults := req.Adults
	if adults < 1 {
		adults = 2
	}

	params := url.Values{}
	params.Set("engine", "google_hotels")
	params.Set("api_key", os.Getenv("SERPAPI_API_KEY"))
	params.Set("q", req.City)
	params.Set("check_in_date", req.CheckIn)
	params.Set("check_out_date", req.CheckOut)
	params.Set("adults", strconv.Itoa(adults))
	params.Set("currency", currency)
	// Pin the point of sale so prices cannot drift with the provider's geo
	// inference — same reasoning as the flights service.
	params.Set("gl", "us")
	params.Set("hl", "en")

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, s.BaseURL+"/search?"+params.Encode(), nil)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to build request: %w", redactTransportError(err))
	}
	httpReq.Header.Set("Accept", "application/json")

	s.calls.upstream.Add(1)
	resp, err := s.Client.Do(httpReq)
	if err != nil {
		return nil, 0, fmt.Errorf("SerpApi hotels request failed: %w", redactTransportError(err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, 0, fmt.Errorf("failed to read SerpApi hotels response: %w", err)
	}
	return body, resp.StatusCode, nil
}

// serpapiHotels is the process-wide singleton, matching the Duffel /
// Ticketmaster / SerpApi-flights convention.
var serpapiHotels = NewSerpapiHotelsService()
