package main

import (
	"bytes"
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

// DuffelService handles Duffel flight API interactions. Unlike Amadeus, Duffel
// authenticates with a static access token (no OAuth exchange), so the service
// just attaches a bearer header and version to each request.
type DuffelService struct {
	Token   string
	BaseURL string
	Version string
	Client  *http.Client

	// Airport/city suggestions are stable; cache them to avoid re-billing
	// repeat lookups. Flight offers are time-sensitive and never cached.
	placesCache *ttlCache[[]Airport]
}

// Airport is a normalized airport/city result used for origin/destination
// autocomplete. Inputs to flight search are IATA codes.
type Airport struct {
	IataCode string `json:"iata_code"`
	Name     string `json:"name"`
	City     string `json:"city,omitempty"`
	Country  string `json:"country,omitempty"`
	SubType  string `json:"sub_type,omitempty"` // airport | city
	// Pointers + omitempty: entries Duffel returns without coordinates (some
	// city-type places) keep their JSON shape byte-identical to before.
	Latitude  *float64 `json:"latitude,omitempty"`
	Longitude *float64 `json:"longitude,omitempty"`
}

// FlightLeg is a single flown segment within an offer.
type FlightLeg struct {
	From         string `json:"from"`
	To           string `json:"to"`
	Carrier      string `json:"carrier"`
	FlightNumber string `json:"flight_number"`
	DepartTime   string `json:"depart_time"`
	ArriveTime   string `json:"arrive_time"`
}

// FlightOffer is a normalized flight offer. The *_score fields are populated by
// the optimizer (see flight_optimizer.go); they are zero until ranking runs.
type FlightOffer struct {
	ID             string      `json:"id"`
	Price          float64     `json:"price"`
	Currency       string      `json:"currency"`
	Stops          int         `json:"stops"`
	DurationMin    int         `json:"duration_minutes"`
	Airlines       []string    `json:"airlines"`
	AirlineCode    string      `json:"airline_code,omitempty"`     // owner.iata_code
	AirlineLogoURL string      `json:"airline_logo_url,omitempty"` // owner.logo_symbol_url (SVG)
	DepartTime     string      `json:"depart_time"`
	ArriveTime     string      `json:"arrive_time"`
	Segments       []FlightLeg `json:"segments"`
	BookingURL     string      `json:"booking_url,omitempty"`

	// Included baggage, per passenger: the worst case across every flown
	// segment of every slice — a bag counts only when each segment grants it
	// to each passenger. Personal items aren't modeled by Duffel (always
	// allowed), so a basic fare typically reports 0/0 here.
	IncludedCarryOn int `json:"included_carry_on"`
	IncludedChecked int `json:"included_checked"`

	// Effective pricing, populated only when the search asked for a carry_on
	// or checked tier (see searchFlightsWithBaggage). BagFee is the total cost
	// of adding the needed bag for every passenger across all slices.
	BaggageStatus  string  `json:"baggage_status,omitempty"`  // "included" | "paid" | "unknown"
	BagFee         float64 `json:"bag_fee,omitempty"`         // > 0 only when "paid"
	EffectivePrice float64 `json:"effective_price,omitempty"` // Price + BagFee; == Price when "included"; unset when "unknown"

	// Round-trip only: the return slice's legs and duration. Empty/zero for
	// one-way searches. Price is always the total across all slices; the
	// top-level Stops/DurationMin/times stay outbound-based so ranking and
	// existing one-way consumers are unchanged.
	ReturnSegments    []FlightLeg `json:"return_segments,omitempty"`
	ReturnDurationMin int         `json:"return_duration_minutes,omitempty"`

	// Scoring (filled by RankFlightOffers)
	Score         float64 `json:"score"`
	PriceScore    float64 `json:"price_score"`
	DurationScore float64 `json:"duration_score"`
	StopsScore    float64 `json:"stops_score"`
}

// FlightSearchRequest is the inbound request shape for /flights/search.
type FlightSearchRequest struct {
	Origin      string `json:"origin"`      // IATA code
	Destination string `json:"destination"` // IATA code
	DepartDate  string `json:"depart_date"` // YYYY-MM-DD
	ReturnDate  string `json:"return_date,omitempty"`
	Adults      int    `json:"adults"`
	ChildAges   []int  `json:"child_ages,omitempty"` // one entry per child; Duffel requires an age
	CabinClass  string `json:"cabin_class,omitempty"`
	Baggage     string `json:"baggage,omitempty"` // "personal_item" (default) | "carry_on" | "checked"
	OptimizeFor string `json:"optimize_for"`      // "cost" | "time" | "balanced"

	// SupplierTimeoutMS, when set, is passed to Duffel as the supplier_timeout
	// query param (milliseconds) so slow airlines are dropped instead of
	// dragging the whole search. Internal-only (connectivity checks); never
	// part of the public /flights/search request shape.
	SupplierTimeoutMS int `json:"-"`
}

// allowedCabinClasses are Duffel's cabin_class values; empty input defaults
// to economy.
var allowedCabinClasses = map[string]bool{
	"economy": true, "premium_economy": true, "business": true, "first": true,
}

// Baggage tiers describe the biggest bag the traveler needs. Duffel only
// models carry_on and checked allowances; a personal item is always allowed,
// so that tier is the no-op default matching pre-baggage behavior.
const (
	baggagePersonalItem = "personal_item"
	baggageCarryOn      = "carry_on"
	baggageChecked      = "checked"
)

var allowedBaggageTiers = map[string]bool{
	baggagePersonalItem: true, baggageCarryOn: true, baggageChecked: true,
}

// BaggageStatus values (set only on carry_on/checked searches).
const (
	baggageStatusIncluded = "included" // fare already includes the bag
	baggageStatusPaid     = "paid"     // bag priced via Duffel; EffectivePrice = Price + BagFee
	baggageStatusUnknown  = "unknown"  // bag needed but not priceable via Duffel
)

// normalizeBaggage returns a valid tier; empty defaults to personal_item.
func normalizeBaggage(s string) string {
	key := strings.ToLower(strings.TrimSpace(s))
	if key == "" {
		return baggagePersonalItem
	}
	return key
}

// maxOffers caps how many offers we keep from a Duffel search before ranking,
// to bound work and response size (Duffel can return hundreds).
const maxOffers = 50

// NewDuffelService creates a new Duffel service, reading the access token from
// the environment. A missing token is a soft failure (a warning, like the
// Google key) so the rest of the API stays healthy; calls fail clearly later.
func NewDuffelService() *DuffelService {
	token := os.Getenv("DUFFEL_ACCESS_TOKEN")
	if token == "" {
		fmt.Println("Warning: DUFFEL_ACCESS_TOKEN not set; flight search disabled")
	}

	baseURL := os.Getenv("DUFFEL_BASE_URL")
	if baseURL == "" {
		baseURL = "https://api.duffel.com"
	}
	version := os.Getenv("DUFFEL_VERSION")
	if version == "" {
		version = "v2"
	}

	return &DuffelService{
		Token:       token,
		BaseURL:     strings.TrimRight(baseURL, "/"),
		Version:     version,
		Client:      &http.Client{Timeout: 60 * time.Second},
		placesCache: newTTLCache[[]Airport](24*time.Hour, 5000),
	}
}

// newRequest builds a Duffel request with the standard auth/version headers.
func (d *DuffelService) newRequest(ctx context.Context, method, path string, body io.Reader) (*http.Request, error) {
	if d.Token == "" {
		return nil, fmt.Errorf("Duffel access token not configured")
	}
	req, err := http.NewRequestWithContext(ctx, method, d.BaseURL+path, body)
	if err != nil {
		return nil, fmt.Errorf("failed to build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+d.Token)
	req.Header.Set("Duffel-Version", d.Version)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req, nil
}

// do executes the request and returns the raw body, surfacing API error payloads.
func (d *DuffelService) do(req *http.Request) ([]byte, error) {
	resp, err := d.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("Duffel API error (%d): %s", resp.StatusCode, string(body))
	}
	return body, nil
}

// SearchAirports resolves a free-text keyword to airports/cities (for origin
// and destination autocomplete).
func (d *DuffelService) SearchAirports(ctx context.Context, keyword string) ([]Airport, error) {
	params := url.Values{}
	params.Set("query", keyword)
	return d.placeSuggestions(ctx, params)
}

// nearbyAirportRadiusMeters bounds the geographic airport lookup. 100km comfortably
// covers an island/metro area; Duffel returns matches sorted nearest-first.
const nearbyAirportRadiusMeters = 100000

// NearbyAirports resolves a coordinate to nearby airports/cities, sorted
// nearest-first. Used to map an itinerary place (e.g. a village like Imerovigli)
// to a bookable airport (e.g. Santorini/JTR) when its name has no IATA match.
func (d *DuffelService) NearbyAirports(ctx context.Context, lat, lng float64) ([]Airport, error) {
	params := url.Values{}
	params.Set("lat", strconv.FormatFloat(lat, 'f', -1, 64))
	params.Set("lng", strconv.FormatFloat(lng, 'f', -1, 64))
	params.Set("rad", strconv.Itoa(nearbyAirportRadiusMeters))
	return d.placeSuggestions(ctx, params)
}

// placeSuggestions queries Duffel's /places/suggestions with the given params and
// normalizes the response to []Airport (skipping entries without an IATA code).
func (d *DuffelService) placeSuggestions(ctx context.Context, params url.Values) ([]Airport, error) {
	cacheKey := params.Encode()
	if cached, ok := d.placesCache.get(cacheKey); ok {
		return cached, nil
	}

	req, err := d.newRequest(ctx, http.MethodGet, "/places/suggestions?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	body, err := d.do(req)
	if err != nil {
		return nil, err
	}

	var result struct {
		Data []struct {
			Type            string   `json:"type"`
			Name            string   `json:"name"`
			IataCode        string   `json:"iata_code"`
			CityName        string   `json:"city_name"`
			IataCountryCode string   `json:"iata_country_code"`
			Latitude        *float64 `json:"latitude"`
			Longitude       *float64 `json:"longitude"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse places response: %w", err)
	}

	airports := make([]Airport, 0, len(result.Data))
	for _, p := range result.Data {
		if p.IataCode == "" {
			continue
		}
		airports = append(airports, Airport{
			IataCode:  p.IataCode,
			Name:      p.Name,
			City:      p.CityName,
			Country:   p.IataCountryCode,
			SubType:   p.Type,
			Latitude:  p.Latitude,
			Longitude: p.Longitude,
		})
	}
	d.placesCache.set(cacheKey, airports)
	return airports, nil
}

// duffelSegment/duffelSlice mirror the parts of Duffel's offer shape we read.
type duffelSegment struct {
	Origin struct {
		IataCode string `json:"iata_code"`
	} `json:"origin"`
	Destination struct {
		IataCode string `json:"iata_code"`
	} `json:"destination"`
	DepartingAt      string `json:"departing_at"`
	ArrivingAt       string `json:"arriving_at"`
	MarketingCarrier struct {
		Name     string `json:"name"`
		IataCode string `json:"iata_code"`
	} `json:"marketing_carrier"`
	MarketingCarrierFlightNumber string `json:"marketing_carrier_flight_number"`
	Passengers                   []struct {
		Baggages []struct {
			Type     string `json:"type"` // "carry_on" | "checked"
			Quantity int    `json:"quantity"`
		} `json:"baggages"`
	} `json:"passengers"`
}

type duffelSlice struct {
	Duration string          `json:"duration"`
	Segments []duffelSegment `json:"segments"`
}

// includedBagCounts reduces an offer's per-segment, per-passenger baggage
// allowances to the worst case: the counts returned are what EVERY passenger
// gets on EVERY flown segment. A segment reporting no passenger data counts
// as granting nothing (conservative — better to under-promise a bag than to
// hide a fee).
func includedBagCounts(slices []duffelSlice) (carryOn, checked int) {
	first := true
	for _, sl := range slices {
		for _, seg := range sl.Segments {
			if len(seg.Passengers) == 0 {
				return 0, 0
			}
			for _, p := range seg.Passengers {
				co, ch := 0, 0
				for _, b := range p.Baggages {
					switch b.Type {
					case baggageCarryOn:
						co += b.Quantity
					case baggageChecked:
						ch += b.Quantity
					}
				}
				if first {
					carryOn, checked = co, ch
					first = false
					continue
				}
				carryOn = min(carryOn, co)
				checked = min(checked, ch)
			}
		}
	}
	return carryOn, checked
}

// SearchFlightOffers creates a Duffel offer request (with offers returned
// inline) and returns normalized offers (unranked). Stops/duration/times are
// taken from the outbound slice; on round trips the return slice is exposed
// via ReturnSegments/ReturnDurationMin (price is always the round-trip total).
func (d *DuffelService) SearchFlightOffers(ctx context.Context, req FlightSearchRequest) ([]FlightOffer, error) {
	adults := req.Adults
	if adults < 1 {
		adults = 1
	}

	// Build the request payload. One slice for one-way, two for round-trip.
	type sliceReq struct {
		Origin        string `json:"origin"`
		Destination   string `json:"destination"`
		DepartureDate string `json:"departure_date"`
	}
	type passengerReq struct {
		Type string `json:"type,omitempty"`
		Age  *int   `json:"age,omitempty"`
	}
	slices := []sliceReq{{
		Origin:        strings.ToUpper(req.Origin),
		Destination:   strings.ToUpper(req.Destination),
		DepartureDate: req.DepartDate,
	}}
	if req.ReturnDate != "" {
		slices = append(slices, sliceReq{
			Origin:        strings.ToUpper(req.Destination),
			Destination:   strings.ToUpper(req.Origin),
			DepartureDate: req.ReturnDate,
		})
	}
	passengers := make([]passengerReq, 0, adults+len(req.ChildAges))
	for i := 0; i < adults; i++ {
		passengers = append(passengers, passengerReq{Type: "adult"})
	}
	// Duffel identifies non-adult passengers by age, not a type string.
	for _, age := range req.ChildAges {
		a := age
		passengers = append(passengers, passengerReq{Age: &a})
	}
	cabin := strings.ToLower(strings.TrimSpace(req.CabinClass))
	if cabin == "" {
		cabin = "economy"
	}
	payload := map[string]any{
		"data": map[string]any{
			"slices":      slices,
			"passengers":  passengers,
			"cabin_class": cabin,
		},
	}
	buf, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("failed to encode offer request: %w", err)
	}

	path := "/air/offer_requests?return_offers=true"
	if req.SupplierTimeoutMS > 0 {
		path += "&supplier_timeout=" + strconv.Itoa(req.SupplierTimeoutMS)
	}
	httpReq, err := d.newRequest(ctx, http.MethodPost, path, bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	body, err := d.do(httpReq)
	if err != nil {
		return nil, err
	}

	var result struct {
		Data struct {
			Offers []struct {
				ID            string `json:"id"`
				TotalAmount   string `json:"total_amount"`
				TotalCurrency string `json:"total_currency"`
				Owner         struct {
					IataCode      string `json:"iata_code"`
					Name          string `json:"name"`
					LogoSymbolURL string `json:"logo_symbol_url"`
				} `json:"owner"`
				Slices []duffelSlice `json:"slices"`
			} `json:"offers"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse offers response: %w", err)
	}

	offers := make([]FlightOffer, 0, len(result.Data.Offers))
	for _, o := range result.Data.Offers {
		if len(o.Slices) == 0 || len(o.Slices[0].Segments) == 0 {
			continue
		}
		outbound := o.Slices[0]
		segs := outbound.Segments

		airlineSet := map[string]bool{}
		airlines := []string{}
		toLegs := func(segs []duffelSegment) []FlightLeg {
			legs := make([]FlightLeg, 0, len(segs))
			for _, s := range segs {
				name := s.MarketingCarrier.Name
				if name == "" {
					name = s.MarketingCarrier.IataCode
				}
				if name != "" && !airlineSet[name] {
					airlineSet[name] = true
					airlines = append(airlines, name)
				}
				legs = append(legs, FlightLeg{
					From:         s.Origin.IataCode,
					To:           s.Destination.IataCode,
					Carrier:      name,
					FlightNumber: s.MarketingCarrier.IataCode + s.MarketingCarrierFlightNumber,
					DepartTime:   s.DepartingAt,
					ArriveTime:   s.ArrivingAt,
				})
			}
			return legs
		}
		legs := toLegs(segs)

		// Round-trip: normalize the return slice too so callers can render
		// both directions. TotalAmount already covers all slices.
		var returnLegs []FlightLeg
		returnDur := 0
		if len(o.Slices) > 1 && len(o.Slices[1].Segments) > 0 {
			returnLegs = toLegs(o.Slices[1].Segments)
			returnDur = parseISO8601Duration(o.Slices[1].Duration)
		}

		price, _ := strconv.ParseFloat(o.TotalAmount, 64)
		carryOn, checked := includedBagCounts(o.Slices)
		offers = append(offers, FlightOffer{
			ID:                o.ID,
			Price:             price,
			Currency:          o.TotalCurrency,
			IncludedCarryOn:   carryOn,
			IncludedChecked:   checked,
			Stops:             len(segs) - 1,
			DurationMin:       parseISO8601Duration(outbound.Duration),
			Airlines:          airlines,
			AirlineCode:       o.Owner.IataCode,
			AirlineLogoURL:    o.Owner.LogoSymbolURL,
			DepartTime:        segs[0].DepartingAt,
			ArriveTime:        segs[len(segs)-1].ArrivingAt,
			Segments:          legs,
			ReturnSegments:    returnLegs,
			ReturnDurationMin: returnDur,
		})
		if len(offers) >= maxOffers {
			break
		}
	}
	return offers, nil
}

// parseISO8601Duration converts an ISO-8601 duration like "PT5H30M" to minutes.
// Duffel slice durations use hours and minutes (e.g. "PT02H26M").
func parseISO8601Duration(s string) int {
	s = strings.TrimPrefix(s, "PT")
	total := 0
	num := strings.Builder{}
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9':
			num.WriteRune(r)
		case r == 'H':
			h, _ := strconv.Atoi(num.String())
			total += h * 60
			num.Reset()
		case r == 'M':
			m, _ := strconv.Atoi(num.String())
			total += m
			num.Reset()
		default:
			num.Reset()
		}
	}
	return total
}

// duffelService is what one purchasable extra (an available_service) looks
// like on a Duffel offer. One unit of a baggage service adds one bag for one
// of its passenger_ids across all of its segment_ids.
type duffelAvailableService struct {
	ID              string   `json:"id"`
	Type            string   `json:"type"` // we only use "baggage"
	TotalAmount     string   `json:"total_amount"`
	TotalCurrency   string   `json:"total_currency"`
	MaximumQuantity int      `json:"maximum_quantity"`
	SegmentIDs      []string `json:"segment_ids"`
	PassengerIDs    []string `json:"passenger_ids"`
	Metadata        struct {
		Type string `json:"type"` // "carry_on" | "checked"
	} `json:"metadata"`
}

// segmentPassenger is one (flown segment, traveler) pair that needs the
// requested bag covered.
type segmentPassenger struct {
	SegmentID   string
	PassengerID string
}

// GetOfferBagFee fetches an offer's purchasable extras and computes the total
// cost of adding one bag of bagType for every passenger on every segment.
// known=false means the fee cannot be determined (the airline doesn't sell
// that bag via Duffel, coverage is incomplete, or a service is priced in a
// different currency than the fare) — the offer should surface as
// "bag fee unknown", not as an error.
func (d *DuffelService) GetOfferBagFee(ctx context.Context, offerID, bagType, wantCurrency string) (fee float64, known bool, err error) {
	path := "/air/offers/" + url.PathEscape(offerID) + "?return_available_services=true"
	httpReq, err := d.newRequest(ctx, http.MethodGet, path, nil)
	if err != nil {
		return 0, false, err
	}
	body, err := d.do(httpReq)
	if err != nil {
		return 0, false, err
	}

	var result struct {
		Data struct {
			Passengers []struct {
				ID string `json:"id"`
			} `json:"passengers"`
			Slices []struct {
				Segments []struct {
					ID string `json:"id"`
				} `json:"segments"`
			} `json:"slices"`
			AvailableServices []duffelAvailableService `json:"available_services"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return 0, false, fmt.Errorf("failed to parse offer services response: %w", err)
	}

	var pairs []segmentPassenger
	for _, sl := range result.Data.Slices {
		for _, seg := range sl.Segments {
			for _, p := range result.Data.Passengers {
				pairs = append(pairs, segmentPassenger{SegmentID: seg.ID, PassengerID: p.ID})
			}
		}
	}
	if len(pairs) == 0 {
		return 0, false, nil
	}
	fee, known = computeBagFee(pairs, result.Data.AvailableServices, bagType, wantCurrency)
	return fee, known, nil
}

// computeBagFee prices one bag of bagType for every (segment, passenger) pair
// using the offer's purchasable services. Greedy: each uncovered pair buys one
// unit of the cheapest service covering it; that unit covers the passenger
// across all of the service's segments. Any pair no service can cover, or any
// needed service priced in a currency other than wantCurrency, makes the fee
// unknowable (false). Deliberately not optimal set cover — real Duffel
// services are per-passenger-per-slice and greedy is exact for that shape.
func computeBagFee(pairs []segmentPassenger, services []duffelAvailableService, bagType, wantCurrency string) (float64, bool) {
	type bagService struct {
		duffelAvailableService
		price    float64
		bought   int
		segments map[string]bool
		pax      map[string]bool
	}
	candidates := make([]*bagService, 0, len(services))
	for _, s := range services {
		if s.Type != "baggage" || s.Metadata.Type != bagType {
			continue
		}
		price, err := strconv.ParseFloat(s.TotalAmount, 64)
		if err != nil {
			continue
		}
		bs := &bagService{duffelAvailableService: s, price: price,
			segments: map[string]bool{}, pax: map[string]bool{}}
		for _, id := range s.SegmentIDs {
			bs.segments[id] = true
		}
		for _, id := range s.PassengerIDs {
			bs.pax[id] = true
		}
		candidates = append(candidates, bs)
	}

	covered := map[segmentPassenger]bool{}
	total := 0.0
	for _, pair := range pairs {
		if covered[pair] {
			continue
		}
		var best *bagService
		for _, c := range candidates {
			if !c.segments[pair.SegmentID] || !c.pax[pair.PassengerID] {
				continue
			}
			// MaximumQuantity 0 means Duffel omitted the cap; treat as uncapped.
			if c.MaximumQuantity > 0 && c.bought >= c.MaximumQuantity {
				continue
			}
			if best == nil || c.price < best.price {
				best = c
			}
		}
		if best == nil {
			return 0, false
		}
		if best.TotalCurrency != wantCurrency {
			return 0, false
		}
		best.bought++
		total += best.price
		// One unit adds this passenger's bag on every segment the service spans.
		for segID := range best.segments {
			covered[segmentPassenger{SegmentID: segID, PassengerID: pair.PassengerID}] = true
		}
	}
	return total, true
}
