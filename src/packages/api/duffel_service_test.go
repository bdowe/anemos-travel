package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// stubDuffel captures the offer-request payload the service sends.
func stubDuffel(t *testing.T, captured *map[string]any) *DuffelService {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(body, captured); err != nil {
			t.Fatalf("stub could not parse request body: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":{"offers":[]}}`))
	}))
	t.Cleanup(srv.Close)
	return &DuffelService{
		Token:   "test-token",
		BaseURL: srv.URL,
		Version: "v2",
		Client:  &http.Client{Timeout: 5 * time.Second},
	}
}

func TestSearchFlightOffersPassengerAndCabinPayload(t *testing.T) {
	var captured map[string]any
	d := stubDuffel(t, &captured)

	_, err := d.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "bos", Destination: "cdg", DepartDate: "2026-09-01",
		Adults: 2, ChildAges: []int{5, 9}, CabinClass: "Business",
	})
	if err != nil {
		t.Fatalf("SearchFlightOffers: %v", err)
	}

	data := captured["data"].(map[string]any)
	if got := data["cabin_class"]; got != "business" {
		t.Fatalf("cabin_class = %v, want business (lowercased)", got)
	}
	passengers := data["passengers"].([]any)
	if len(passengers) != 4 {
		t.Fatalf("passengers = %d, want 4 (2 adults + 2 children)", len(passengers))
	}
	adults := 0
	var childAges []int
	for _, p := range passengers {
		pm := p.(map[string]any)
		switch {
		case pm["type"] == "adult":
			adults++
		case pm["age"] != nil:
			childAges = append(childAges, int(pm["age"].(float64)))
			if _, hasType := pm["type"]; hasType {
				t.Fatal("child passenger must not carry a type field")
			}
		default:
			t.Fatalf("unexpected passenger entry: %v", pm)
		}
	}
	if adults != 2 {
		t.Fatalf("adults=%d, want 2", adults)
	}
	// Each child must carry its own distinct age through to Duffel.
	if len(childAges) != 2 || childAges[0] != 5 || childAges[1] != 9 {
		t.Fatalf("child ages = %v, want [5 9]", childAges)
	}
}

// stubDuffelWithOffers serves a canned offers payload and captures the request.
func stubDuffelWithOffers(t *testing.T, captured *map[string]any, offersJSON string) *DuffelService {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(body, captured); err != nil {
			t.Fatalf("stub could not parse request body: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(offersJSON))
	}))
	t.Cleanup(srv.Close)
	return &DuffelService{
		Token:   "test-token",
		BaseURL: srv.URL,
		Version: "v2",
		Client:  &http.Client{Timeout: 5 * time.Second},
	}
}

func TestSearchFlightOffersRoundTrip(t *testing.T) {
	var captured map[string]any
	d := stubDuffelWithOffers(t, &captured, `{"data":{"offers":[{
		"id":"off_rt","total_amount":"842.40","total_currency":"USD",
		"owner":{"iata_code":"AF","name":"Air France"},
		"slices":[
			{"duration":"PT7H30M","segments":[{
				"origin":{"iata_code":"JFK"},"destination":{"iata_code":"CDG"},
				"departing_at":"2026-09-01T18:00:00","arriving_at":"2026-09-02T07:30:00",
				"marketing_carrier":{"name":"Air France","iata_code":"AF"},
				"marketing_carrier_flight_number":"11"}]},
			{"duration":"PT8H15M","segments":[{
				"origin":{"iata_code":"CDG"},"destination":{"iata_code":"JFK"},
				"departing_at":"2026-09-10T10:00:00","arriving_at":"2026-09-10T12:15:00",
				"marketing_carrier":{"name":"Delta","iata_code":"DL"},
				"marketing_carrier_flight_number":"263"}]}
		]}]}}`)

	offers, err := d.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "JFK", Destination: "CDG",
		DepartDate: "2026-09-01", ReturnDate: "2026-09-10", Adults: 1,
	})
	if err != nil {
		t.Fatalf("SearchFlightOffers: %v", err)
	}

	// The request must carry two slices, with the return reversed.
	slices := captured["data"].(map[string]any)["slices"].([]any)
	if len(slices) != 2 {
		t.Fatalf("request slices = %d, want 2", len(slices))
	}
	ret := slices[1].(map[string]any)
	if ret["origin"] != "CDG" || ret["destination"] != "JFK" || ret["departure_date"] != "2026-09-10" {
		t.Fatalf("return slice = %v, want CDG->JFK on 2026-09-10", ret)
	}

	if len(offers) != 1 {
		t.Fatalf("offers = %d, want 1", len(offers))
	}
	o := offers[0]
	// Outbound-based fields are unchanged from one-way behavior.
	if len(o.Segments) != 1 || o.Segments[0].From != "JFK" || o.Segments[0].To != "CDG" {
		t.Fatalf("outbound segments = %v, want JFK->CDG", o.Segments)
	}
	if o.Stops != 0 || o.DurationMin != 7*60+30 {
		t.Fatalf("stops=%d dur=%d, want 0/450", o.Stops, o.DurationMin)
	}
	// The return slice must be preserved for the UI to render both directions.
	if len(o.ReturnSegments) != 1 || o.ReturnSegments[0].From != "CDG" || o.ReturnSegments[0].To != "JFK" {
		t.Fatalf("return segments = %v, want CDG->JFK", o.ReturnSegments)
	}
	if o.ReturnDurationMin != 8*60+15 {
		t.Fatalf("return duration = %d, want 495", o.ReturnDurationMin)
	}
	// Carriers from both directions are surfaced.
	if len(o.Airlines) != 2 || o.Airlines[0] != "Air France" || o.Airlines[1] != "Delta" {
		t.Fatalf("airlines = %v, want [Air France Delta]", o.Airlines)
	}
}

func TestSearchFlightOffersOneWayHasNoReturnFields(t *testing.T) {
	var captured map[string]any
	d := stubDuffelWithOffers(t, &captured, `{"data":{"offers":[{
		"id":"off_ow","total_amount":"420.00","total_currency":"USD",
		"owner":{"iata_code":"AF","name":"Air France"},
		"slices":[{"duration":"PT7H30M","segments":[{
			"origin":{"iata_code":"JFK"},"destination":{"iata_code":"CDG"},
			"departing_at":"2026-09-01T18:00:00","arriving_at":"2026-09-02T07:30:00",
			"marketing_carrier":{"name":"Air France","iata_code":"AF"},
			"marketing_carrier_flight_number":"11"}]}]}]}}`)

	offers, err := d.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "JFK", Destination: "CDG", DepartDate: "2026-09-01", Adults: 1,
	})
	if err != nil {
		t.Fatalf("SearchFlightOffers: %v", err)
	}
	if got := len(captured["data"].(map[string]any)["slices"].([]any)); got != 1 {
		t.Fatalf("request slices = %d, want 1", got)
	}
	if len(offers) != 1 || offers[0].ReturnSegments != nil || offers[0].ReturnDurationMin != 0 {
		t.Fatalf("one-way offer must carry no return fields: %+v", offers)
	}
}

// SupplierTimeoutMS is internal plumbing for indicative connectivity checks:
// present as a query param only when set, and never part of the JSON shape.
func TestSearchFlightOffersSupplierTimeout(t *testing.T) {
	var queries []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		queries = append(queries, r.URL.RawQuery)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":{"offers":[]}}`))
	}))
	t.Cleanup(srv.Close)
	d := &DuffelService{Token: "test-token", BaseURL: srv.URL, Version: "v2",
		Client: &http.Client{Timeout: 5 * time.Second}}

	base := FlightSearchRequest{Origin: "SJU", Destination: "NAS", DepartDate: "2026-09-15", Adults: 1}
	if _, err := d.SearchFlightOffers(context.Background(), base); err != nil {
		t.Fatalf("SearchFlightOffers: %v", err)
	}
	withTimeout := base
	withTimeout.SupplierTimeoutMS = 10000
	if _, err := d.SearchFlightOffers(context.Background(), withTimeout); err != nil {
		t.Fatalf("SearchFlightOffers: %v", err)
	}

	if strings.Contains(queries[0], "supplier_timeout") {
		t.Fatalf("supplier_timeout must be absent when unset, got %q", queries[0])
	}
	if !strings.Contains(queries[1], "supplier_timeout=10000") {
		t.Fatalf("supplier_timeout=10000 missing, got %q", queries[1])
	}
}

func TestSearchFlightOffersDefaultsToEconomy(t *testing.T) {
	var captured map[string]any
	d := stubDuffel(t, &captured)

	if _, err := d.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "BOS", Destination: "CDG", DepartDate: "2026-09-01", Adults: 1,
	}); err != nil {
		t.Fatalf("SearchFlightOffers: %v", err)
	}
	data := captured["data"].(map[string]any)
	if got := data["cabin_class"]; got != "economy" {
		t.Fatalf("cabin_class = %v, want economy default", got)
	}
	if got := len(data["passengers"].([]any)); got != 1 {
		t.Fatalf("passengers = %d, want 1", got)
	}
}

// A 200-with-empty places answer must not be cached: entries live 24h, and
// pinning a transient empty payload would erase an airport (and the trip
// map's home-airport pin) for a day, for every user resolving that code.
// Non-empty results ARE cached.
func TestPlaceSuggestionsDoesNotCacheEmptyResults(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Content-Type", "application/json")
		if hits <= 2 {
			w.Write([]byte(`{"data":[]}`))
			return
		}
		w.Write([]byte(`{"data":[{"type":"airport","name":"Los Angeles International Airport","iata_code":"LAX","city_name":"Los Angeles","iata_country_code":"US","latitude":33.9425,"longitude":-118.408}]}`))
	}))
	t.Cleanup(srv.Close)
	d := &DuffelService{
		Token:       "test-token",
		BaseURL:     srv.URL,
		Version:     "v2",
		Client:      &http.Client{Timeout: 5 * time.Second},
		placesCache: newTTLCache[[]Airport](time.Minute, 10),
	}

	ctx := context.Background()
	if got, err := d.SearchAirports(ctx, "LAX"); err != nil || len(got) != 0 {
		t.Fatalf("first call = %v, %v; want empty success", got, err)
	}
	// The empty answer was not cached: the second call reaches upstream again.
	if _, err := d.SearchAirports(ctx, "LAX"); err != nil {
		t.Fatalf("second call: %v", err)
	}
	if hits != 2 {
		t.Fatalf("upstream hits after two empty rounds = %d, want 2", hits)
	}
	// The third call gets a real result...
	if got, err := d.SearchAirports(ctx, "LAX"); err != nil || len(got) != 1 {
		t.Fatalf("third call = %v, %v; want the LAX row", got, err)
	}
	// ...which IS cached: a fourth call must not touch upstream.
	if _, err := d.SearchAirports(ctx, "LAX"); err != nil {
		t.Fatalf("fourth call: %v", err)
	}
	if hits != 3 {
		t.Fatalf("upstream hits = %d, want 3 (non-empty result served from cache)", hits)
	}
}

// A Duffel upstream failure must answer 502 with a JSON body: the old
// http.Error(500, text/plain) read as our fault rather than the provider's,
// and clients treat 502 on a GET as retryable.
func TestAirportsSearchHandlerDuffelFailureIs502JSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "duffel exploded", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	old := duffelService
	duffelService = &DuffelService{
		Token:       "test-token",
		BaseURL:     srv.URL,
		Version:     "v2",
		Client:      &http.Client{Timeout: 5 * time.Second},
		placesCache: newTTLCache[[]Airport](time.Minute, 10),
	}
	t.Cleanup(func() { duffelService = old })

	rec := httptest.NewRecorder()
	airportsSearchHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/flights/airports?q=LAX", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("502 body is not JSON (%v): %s", err, rec.Body.String())
	}
}

func TestPlaceSuggestionsCarriesCoordinates(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":[
			{"type":"airport","name":"Boston Logan International Airport","iata_code":"BOS","city_name":"Boston","iata_country_code":"US","latitude":42.365613,"longitude":-71.009537},
			{"type":"city","name":"Boston","iata_code":"BOS","iata_country_code":"US"}
		]}`))
	}))
	t.Cleanup(srv.Close)
	d := &DuffelService{
		Token:   "test-token",
		BaseURL: srv.URL,
		Version: "v2",
		Client:  &http.Client{Timeout: 5 * time.Second},
		// placeSuggestions dereferences the cache unconditionally; the
		// direct-literal stub skips NewDuffelService.
		placesCache: newTTLCache[[]Airport](time.Minute, 10),
	}

	got, err := d.SearchAirports(context.Background(), "BOS")
	if err != nil {
		t.Fatalf("SearchAirports: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("results = %d, want 2", len(got))
	}

	airport := got[0]
	if airport.Latitude == nil || airport.Longitude == nil {
		t.Fatal("airport entry must carry Duffel's coordinates")
	}
	if *airport.Latitude != 42.365613 || *airport.Longitude != -71.009537 {
		t.Fatalf("airport coords = %v,%v, want 42.365613,-71.009537", *airport.Latitude, *airport.Longitude)
	}

	city := got[1]
	if city.Latitude != nil || city.Longitude != nil {
		t.Fatal("entry without coords must keep nil pointers, not 0,0")
	}
	// Coordless entries must marshal byte-identically to the pre-coordinate
	// shape (omitempty on the pointers).
	out, err := json.Marshal(city)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(out), "latitude") || strings.Contains(string(out), "longitude") {
		t.Fatalf("coordless Airport JSON must omit coordinate keys, got %s", out)
	}
}
