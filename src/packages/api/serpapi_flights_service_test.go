package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// --- helpers ---------------------------------------------------------------

// swapSerpapiStub serves handler and swaps the process-wide serpapiFlights
// (mirroring swapConnStub: the singleton is set at package init, so a BaseURL
// env var alone can't reach it in-process), and switches the temporary
// provider on via env — Active/Configured are call-time reads, so t.Setenv
// works. The dailyCounter is built without a janitor to avoid leaking a
// goroutine per test.
func swapSerpapiStub(t *testing.T, handler http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	stub := &SerpapiFlightsService{
		BaseURL:     srv.URL,
		Client:      &http.Client{Timeout: 5 * time.Second},
		offersCache: newTTLCache[[]FlightOffer](time.Hour, 100),
		daily:       &dailyCounter{entries: map[string]*dailyEntry{}},
	}
	old := serpapiFlights
	serpapiFlights = stub
	t.Cleanup(func() { serpapiFlights = old })
	t.Setenv("FLIGHT_OFFERS_PROVIDER", "serpapi")
	t.Setenv("SERPAPI_API_KEY", "test-serpapi-key")
}

// failingDuffel returns a DuffelService whose upstream fails the test on any
// request — proof that a code path never touches Duffel.
func failingDuffel(t *testing.T) *DuffelService {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("unexpected Duffel request: %s %s", r.Method, r.URL.Path)
		http.Error(w, "unexpected", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	return &DuffelService{Token: "test-token", BaseURL: srv.URL, Version: "v2",
		Client:      &http.Client{Timeout: 5 * time.Second},
		placesCache: newTTLCache[[]Airport](time.Hour, 100)}
}

// serpapiItem renders one SerpApi itinerary. Each segment is
// "FROM,TO,airline,flight_number,departTime,arriveTime".
func serpapiItem(price float64, totalDuration int, segments ...[6]string) string {
	segs := make([]string, 0, len(segments))
	for _, s := range segments {
		segs = append(segs, `{
			"departure_airport":{"name":"dep","id":"`+s[0]+`","time":"`+s[4]+`"},
			"arrival_airport":{"name":"arr","id":"`+s[1]+`","time":"`+s[5]+`"},
			"airline":"`+s[2]+`","flight_number":"`+s[3]+`"}`)
	}
	b, _ := json.Marshal(price)
	return `{"flights":[` + strings.Join(segs, ",") + `],` +
		`"total_duration":` + jsonInt(totalDuration) + `,"price":` + string(b) + `}`
}

func jsonInt(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func serpapiBody(best, other []string) string {
	return `{"best_flights":[` + strings.Join(best, ",") + `],"other_flights":[` + strings.Join(other, ",") + `]}`
}

// --- tests -------------------------------------------------------------------

// The mapping is the load-bearing surface: every field the Flutter model
// requires non-null must be filled, times must convert to the T-separated
// shape the clock labels and dedup signatures expect, and round trips are
// phase-1 only (price = RT total, no return segments).
func TestSerpapiSearchFlightOffersMapping(t *testing.T) {
	var query map[string]string
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		query = map[string]string{}
		for k, v := range r.URL.Query() {
			query[k] = v[0]
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(serpapiBody(
			[]string{serpapiItem(850, 620,
				[6]string{"JFK", "LHR", "British Airways", "BA 591", "2026-09-15 08:15", "2026-09-15 20:05"},
				[6]string{"LHR", "ATH", "British Airways", "BA 632", "2026-09-15 21:30", "2026-09-16 03:05"})},
			[]string{serpapiItem(910, 700,
				[6]string{"JFK", "ATH", "Aegean", "A3 995", "2026-09-15 17:30", "2026-09-16 09:10"})},
		)))
	})

	offers, err := serpapiFlights.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "jfk", Destination: "ath", DepartDate: "2026-09-15", ReturnDate: "2026-09-22", Adults: 1,
	})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(offers) != 2 {
		t.Fatalf("want 2 offers, got %d", len(offers))
	}

	o := offers[0]
	if o.ID != "serpapi:JFK-ATH:2026-09-15:0" {
		t.Errorf("ID = %q", o.ID)
	}
	if o.Price != 850 || o.Currency != serpapiCurrency {
		t.Errorf("price/currency = %v %q", o.Price, o.Currency)
	}
	if o.Stops != 1 || o.DurationMin != 620 {
		t.Errorf("stops/duration = %d %d", o.Stops, o.DurationMin)
	}
	if len(o.Airlines) != 1 || o.Airlines[0] != "British Airways" {
		t.Errorf("airlines = %v (want deduped single entry)", o.Airlines)
	}
	if o.AirlineCode != "BA" {
		t.Errorf("airline code = %q", o.AirlineCode)
	}
	if o.AirlineLogoURL != "" {
		t.Errorf("logo URL must stay empty (PNG vs SvgPicture), got %q", o.AirlineLogoURL)
	}
	if o.DepartTime != "2026-09-15T08:15:00" || o.ArriveTime != "2026-09-16T03:05:00" {
		t.Errorf("times = %q %q", o.DepartTime, o.ArriveTime)
	}
	if len(o.Segments) != 2 || o.Segments[0].FlightNumber != "BA591" || o.Segments[0].From != "JFK" || o.Segments[1].To != "ATH" {
		t.Errorf("segments = %+v", o.Segments)
	}
	if len(o.ReturnSegments) != 0 || o.ReturnDurationMin != 0 {
		t.Errorf("return fields must stay empty on phase-1 round trips")
	}
	if o.IncludedCarryOn != 0 || o.IncludedChecked != 0 || o.BaggageStatus != "" {
		t.Errorf("baggage fields must stay zero: %+v", o)
	}
	if offers[1].AirlineCode != "A3" || offers[1].Airlines[0] != "Aegean" {
		t.Errorf("other_flights offer mapped wrong: %+v", offers[1])
	}

	// Request params: RT phase-1, USD, key, uppercased IATA.
	want := map[string]string{
		"engine": "google_flights", "api_key": "test-serpapi-key",
		"departure_id": "JFK", "arrival_id": "ATH",
		"outbound_date": "2026-09-15", "return_date": "2026-09-22",
		"type": "1", "currency": "USD", "adults": "1",
	}
	for k, v := range want {
		if query[k] != v {
			t.Errorf("query[%s] = %q, want %q", k, query[k], v)
		}
	}
	for _, absent := range []string{"children", "infants_on_lap", "travel_class", "deep_search", "sort_by"} {
		if _, ok := query[absent]; ok {
			t.Errorf("query[%s] should be omitted", absent)
		}
	}
}

func TestSerpapiPassengerAndCabinParams(t *testing.T) {
	var query map[string]string
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		query = map[string]string{}
		for k, v := range r.URL.Query() {
			query[k] = v[0]
		}
		w.Write([]byte(serpapiBody(nil, nil)))
	})

	_, err := serpapiFlights.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "JFK", Destination: "CDG", DepartDate: "2026-10-01",
		Adults: 2, ChildAges: []int{1, 5, 13}, CabinClass: "business",
	})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	// 12+ counts as adult for Google Flights; 2-11 child; <2 lap infant.
	want := map[string]string{
		"type": "2", "adults": "3", "children": "1", "infants_on_lap": "1", "travel_class": "3",
	}
	for k, v := range want {
		if query[k] != v {
			t.Errorf("query[%s] = %q, want %q", k, query[k], v)
		}
	}
	if _, ok := query["return_date"]; ok {
		t.Errorf("one-way search must not send return_date")
	}
}

// With the swap active, a checked-bag search must classify every offer
// "unknown" WITHOUT touching Duffel: the tier-2 bag-fee lookups would 404
// against synthetic SerpApi offer IDs.
func TestSerpapiBaggageSearchSkipsDuffelBagFees(t *testing.T) {
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(serpapiBody([]string{
			serpapiItem(300, 120, [6]string{"AAA", "BBB", "TestAir", "TA 1", "2026-09-01 08:00", "2026-09-01 10:00"}),
			serpapiItem(350, 130, [6]string{"AAA", "BBB", "TestAir", "TA 2", "2026-09-01 11:00", "2026-09-01 13:10"}),
		}, nil)))
	})
	duffel := failingDuffel(t)

	offers, err := searchFlightsWithBaggage(context.Background(), duffel, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1, Baggage: "checked",
	})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(offers) != 2 {
		t.Fatalf("want 2 offers, got %d", len(offers))
	}
	for _, o := range offers {
		if o.BaggageStatus != baggageStatusUnknown {
			t.Errorf("offer %s status = %q, want unknown", o.ID, o.BaggageStatus)
		}
	}
}

// Offers must compose with the provider-agnostic optimizer: scores filled,
// cost ordering, duplicate schedules collapsed keeping the cheaper fare.
func TestSerpapiRankingAndDedupIntegration(t *testing.T) {
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(serpapiBody([]string{
			serpapiItem(300, 240, [6]string{"AAA", "BBB", "TestAir", "TA 1", "2026-09-01 10:00", "2026-09-01 14:00"}),
			serpapiItem(200, 240, [6]string{"AAA", "BBB", "CheapAir", "CA 9", "2026-09-01 10:00", "2026-09-01 14:00"}),
			serpapiItem(400, 240, [6]string{"AAA", "BBB", "TestAir", "TA 3", "2026-09-01 09:00", "2026-09-01 13:00"}),
			serpapiItem(250, 240, [6]string{"AAA", "BBB", "TestAir", "TA 4", "2026-09-01 11:00", "2026-09-01 15:00"}),
		}, nil)))
	})

	offers, err := searchFlightsWithBaggage(context.Background(), failingDuffel(t), FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1, OptimizeFor: "cost",
	})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(offers) != 3 {
		t.Fatalf("want 3 offers after dedup, got %d: %+v", len(offers), offers)
	}
	if offers[0].Price != 200 {
		t.Errorf("cheapest duplicate should win and rank first, got %v", offers[0].Price)
	}
	if offers[0].Score <= 0 || offers[0].PriceScore <= 0 {
		t.Errorf("scores not populated: %+v", offers[0])
	}
}

// Provider failure while the swap is active degrades the chat tool to a
// SUCCESS result carrying a Google Flights deep link: isError would loop the
// model (no per-tool retry guard), and the raw error must never reach it.
func TestSerpapiFallbackDeepLink(t *testing.T) {
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"upstream exploded"}`, http.StatusInternalServerError)
	})

	s := connSession()
	input, _ := json.Marshal(map[string]any{
		"origin": "JFK", "destination": "ATH",
		"depart_date": "2026-09-15", "return_date": "2026-09-22",
	})
	text, isErr := runSearchFlightsTool(s, input)
	if isErr {
		t.Fatalf("fallback must be a non-error result, got error: %s", text)
	}
	if !strings.Contains(text, "google.com/travel/flights") {
		t.Errorf("fallback text lacks the Google Flights link: %s", text)
	}
	if strings.Contains(text, "exploded") {
		t.Errorf("upstream error body leaked into model-facing text: %s", text)
	}
	if body := s.w.(*httptest.ResponseRecorder).Body.String(); strings.Contains(body, "event: flights") {
		t.Errorf("no flights SSE event should be emitted on fallback, got: %s", body)
	}
}

// With the swap active and a key configured, connectivity rides the seam to
// SerpApi: real per-leg numbers come back and Duffel's offers endpoint is
// never touched (IATA-code inputs short-circuit airport resolution).
func TestSerpapiConnectivityRidesTheSwap(t *testing.T) {
	cs := &connStub{}
	swapConnStub(t, cs) // fresh leg cache + proof Duffel sees zero offer requests

	bodies := map[string]string{
		"JFK-ATH": serpapiBody([]string{serpapiItem(612, 635,
			[6]string{"JFK", "ATH", "Aegean", "A3 995", "2026-09-15 17:30", "2026-09-16 09:10"})}, nil),
		"JFK-VIE": serpapiBody(nil, nil), // no service on this date
	}
	var upstream atomic.Int32 // handlers run on concurrent leg goroutines
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		upstream.Add(1)
		w.Write([]byte(bodies[r.URL.Query().Get("departure_id")+"-"+r.URL.Query().Get("arrival_id")]))
	})

	text, isErr := runCheckFlightConnectivityTool(connSession(), connInput(t, "JFK", []string{"ATH", "VIE"}, "2026-09-15", ""))
	if isErr {
		t.Fatalf("tool errored: %s", text)
	}
	if !strings.Contains(text, "JFK→ATH — from USD 612, fastest 10h35m, nonstop available") {
		t.Errorf("SerpApi-backed leg missing real numbers:\n%s", text)
	}
	if !strings.Contains(text, "JFK→VIE — no flights found for this date") {
		t.Errorf("empty SerpApi route should read as no-service:\n%s", text)
	}
	if strings.Contains(text, "unavailable") {
		t.Errorf("swap-active connectivity must no longer report unavailable:\n%s", text)
	}
	if n := upstream.Load(); n != 2 {
		t.Errorf("SerpApi upstream calls = %d, want 2", n)
	}
	if n := cs.requestCount(); n != 0 {
		t.Errorf("connectivity made %d Duffel offer calls while swap active, want 0", n)
	}
}

// Swap active without a key: nothing to call, so the friendly unavailable
// message comes back without touching either provider.
func TestSerpapiConnectivityUnavailableWithoutKey(t *testing.T) {
	cs := &connStub{}
	swapConnStub(t, cs)
	t.Setenv("FLIGHT_OFFERS_PROVIDER", "serpapi")
	t.Setenv("SERPAPI_API_KEY", "")

	text, isErr := runCheckFlightConnectivityTool(connSession(), connInput(t, "JFK", []string{"ATH", "VIE"}, "2026-09-15", ""))
	if isErr {
		t.Fatalf("unavailable must be a non-error result, got error: %s", text)
	}
	if !strings.Contains(text, "search_flights") {
		t.Errorf("unavailable text should steer the model to search_flights: %s", text)
	}
	if n := cs.requestCount(); n != 0 {
		t.Errorf("keyless connectivity made %d provider calls, want 0", n)
	}
}

// The headroom guard: when today's remaining SerpApi quota can't cover the
// uncached legs plus the reserve, the tool bails before spending anything —
// search_flights keeps its slice of the cap.
func TestSerpapiConnectivityQuotaHeadroom(t *testing.T) {
	cs := &connStub{}
	swapConnStub(t, cs)
	var upstream atomic.Int32 // handlers run on concurrent leg goroutines
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		upstream.Add(1)
		w.Write([]byte(serpapiBody(nil, nil)))
	})
	// 2 uncached legs need remaining >= 2 + connectivitySerpapiReserve = 12.
	t.Setenv("SERPAPI_SEARCHES_PER_DAY", "11")

	text, isErr := runCheckFlightConnectivityTool(connSession(), connInput(t, "JFK", []string{"ATH", "VIE"}, "2026-09-15", ""))
	if isErr {
		t.Fatalf("headroom bail must be a non-error result, got error: %s", text)
	}
	if !strings.Contains(text, "unavailable") {
		t.Errorf("expected the unavailable message, got: %s", text)
	}
	if n := upstream.Load(); n != 0 {
		t.Errorf("headroom bail still made %d SerpApi calls, want 0", n)
	}

	// One search over the boundary and the comparison runs.
	t.Setenv("SERPAPI_SEARCHES_PER_DAY", "12")
	text, isErr = runCheckFlightConnectivityTool(connSession(), connInput(t, "JFK", []string{"ATH", "VIE"}, "2026-09-15", ""))
	if isErr || strings.Contains(text, "unavailable") {
		t.Fatalf("with exact headroom the comparison must run: err=%v %s", isErr, text)
	}
	if n := upstream.Load(); n != 2 {
		t.Errorf("SerpApi upstream calls = %d, want 2", n)
	}
}

// While the swap is active the candidate clamp tightens to 3 so one call can
// never fan out more than 6 uncached searches.
func TestSerpapiConnectivityCandidateClamp(t *testing.T) {
	cs := &connStub{}
	swapConnStub(t, cs)
	var upstream atomic.Int32 // handlers run on concurrent leg goroutines
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		upstream.Add(1)
		w.Write([]byte(serpapiBody(nil, nil)))
	})

	text, _ := runCheckFlightConnectivityTool(connSession(),
		connInput(t, "JFK", []string{"AAA", "BBB", "CCC", "DDD", "EEE"}, "2026-09-15", ""))
	if n := upstream.Load(); n != int32(maxConnectivityCandidatesSerpapi) {
		t.Errorf("SerpApi upstream calls = %d, want %d (clamped)", n, maxConnectivityCandidatesSerpapi)
	}
	if !strings.Contains(text, "Only the first 3 candidates were checked") {
		t.Errorf("tightened truncation note missing:\n%s", text)
	}
	if strings.Contains(text, "DDD") || strings.Contains(text, "EEE") {
		t.Errorf("clamped candidates leaked into the summary:\n%s", text)
	}
}

// Unset env is the default and must stay byte-identical: offers come from
// Duffel and the SerpApi service is never consulted.
func TestSerpapiInactiveByDefault(t *testing.T) {
	if serpapiFlights.Active() {
		t.Fatalf("Active() must be false with FLIGHT_OFFERS_PROVIDER unset")
	}
	bs := &baggageStub{searchBody: searchBody(
		bagSearchOffer("off_1", "123.45", "2026-09-01T08:00:00", ""))}
	duffel := newBaggageStubService(t, bs)

	offers, err := flightOffersSearch(context.Background(), duffel, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1,
	})
	if err != nil {
		t.Fatalf("duffel path: %v", err)
	}
	if len(offers) != 1 || offers[0].ID != "off_1" {
		t.Fatalf("expected the Duffel offer, got %+v", offers)
	}
}

// The API key rides in the query string; transport errors embed the full URL
// unless redacted (places_service.go hazard). The key must never appear in an
// error chain.
func TestSerpapiKeyNeverInErrors(t *testing.T) {
	stub := &SerpapiFlightsService{
		BaseURL:     "http://127.0.0.1:1", // nothing listens here
		Client:      &http.Client{Timeout: 500 * time.Millisecond},
		offersCache: newTTLCache[[]FlightOffer](time.Hour, 10),
		daily:       &dailyCounter{entries: map[string]*dailyEntry{}},
	}
	t.Setenv("SERPAPI_API_KEY", "sk-super-secret-key")

	_, err := stub.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "JFK", Destination: "ATH", DepartDate: "2026-09-15", Adults: 1,
	})
	if err == nil {
		t.Fatalf("expected a transport error")
	}
	if strings.Contains(err.Error(), "sk-super-secret-key") {
		t.Errorf("API key leaked into error: %v", err)
	}
	if strings.Contains(err.Error(), "127.0.0.1:1/search?") {
		t.Errorf("request URL leaked into error: %v", err)
	}

	// The request-BUILD path fails as *url.Error{Op:"parse"} whose message
	// quotes the entire raw URL; it must be redacted like the Do path.
	stub.BaseURL = "https://serpapi.com /" // stray space => invalid host
	_, err = stub.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "JFK", Destination: "ATH", DepartDate: "2026-09-15", Adults: 1,
	})
	if err == nil {
		t.Fatalf("expected a build error for the malformed base URL")
	}
	if strings.Contains(err.Error(), "sk-super-secret-key") {
		t.Errorf("API key leaked into build error: %v", err)
	}
}

// SerpApi reports a legitimately empty route as an error field (over HTTP
// 400) — that is "no flights", not an outage, and must not error. The empty
// result must ALSO be cached: retries of a no-flights route (screen Retry
// button, re-asking model) must not burn quota on every repeat.
func TestSerpapiEmptyRouteIsNotAnErrorAndIsCached(t *testing.T) {
	calls := 0
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"Google Flights hasn't returned any results for this query."}`))
	})

	req := FlightSearchRequest{Origin: "AAA", Destination: "ZZZ", DepartDate: "2026-09-15", Adults: 1}
	offers, err := serpapiFlights.SearchFlightOffers(context.Background(), req)
	if err != nil {
		t.Fatalf("empty route must not error: %v", err)
	}
	if len(offers) != 0 {
		t.Fatalf("want 0 offers, got %d", len(offers))
	}
	if _, err := serpapiFlights.SearchFlightOffers(context.Background(), req); err != nil {
		t.Fatalf("cached empty route must not error: %v", err)
	}
	if calls != 1 {
		t.Errorf("identical no-flights retry reached upstream (%d calls), want cached", calls)
	}
}

// A genuine outage (non-2xx without the no-results marker) must error and
// must NOT poison the cache with an empty result.
func TestSerpapiOutageIsAnErrorAndNotCached(t *testing.T) {
	calls := 0
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		http.Error(w, `{"error":"rate limited"}`, http.StatusTooManyRequests)
	})

	req := FlightSearchRequest{Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-15", Adults: 1}
	for i := 0; i < 2; i++ {
		if _, err := serpapiFlights.SearchFlightOffers(context.Background(), req); err == nil {
			t.Fatalf("outage must error (attempt %d)", i+1)
		}
	}
	if calls != 2 {
		t.Errorf("outage responses must not be cached: %d calls, want 2", calls)
	}
}

// The daily cap bounds upstream spend; cache hits stay free and identical
// re-searches within the TTL never consume quota.
func TestSerpapiDailyCapAndCache(t *testing.T) {
	calls := 0
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Write([]byte(serpapiBody([]string{
			serpapiItem(300, 120, [6]string{"AAA", "BBB", "TestAir", "TA 1", "2026-09-01 08:00", "2026-09-01 10:00"}),
		}, nil)))
	})
	t.Setenv("SERPAPI_SEARCHES_PER_DAY", "1")

	req := FlightSearchRequest{Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1}
	first, err := serpapiFlights.SearchFlightOffers(context.Background(), req)
	if err != nil || len(first) != 1 {
		t.Fatalf("first search: %v %d", err, len(first))
	}

	// Identical search: cache hit, no upstream call, no quota burn — and the
	// hit must be a copy (ranking writes scores in place on returned slices).
	cached, err := serpapiFlights.SearchFlightOffers(context.Background(), req)
	if err != nil {
		t.Fatalf("cached search: %v", err)
	}
	cached[0].Score = 9.9
	again, _ := serpapiFlights.SearchFlightOffers(context.Background(), req)
	if again[0].Score != 0 {
		t.Errorf("cache handed out a shared backing array (score mutation visible)")
	}
	if calls != 1 {
		t.Errorf("cache hits must not reach upstream: %d calls", calls)
	}

	// A different route needs upstream and the cap (1/day) is spent.
	_, err = serpapiFlights.SearchFlightOffers(context.Background(), FlightSearchRequest{
		Origin: "AAA", Destination: "CCC", DepartDate: "2026-09-01", Adults: 1,
	})
	if err == nil || !strings.Contains(err.Error(), "daily search cap") {
		t.Errorf("expected the daily-cap error, got %v", err)
	}
	if calls != 1 {
		t.Errorf("capped search must not reach upstream: %d calls", calls)
	}
}
