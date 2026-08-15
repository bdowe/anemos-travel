package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// --- helpers ---------------------------------------------------------------

// swapHotelStub points the process-wide serpapiHotels singleton at a fake
// upstream. Like swapSerpapiStub, the singleton is built at package init so a
// SERPAPI_BASE_URL env var alone cannot reach it; the dailyCounter is built
// without a janitor so no goroutine leaks per test.
func swapHotelStub(t *testing.T, handler http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	stub := &SerpapiHotelsService{
		BaseURL: srv.URL,
		Client:  &http.Client{Timeout: 5 * time.Second},
		cache:   newTTLCache[[]HotelStay](time.Hour, 100),
		daily:   &dailyCounter{entries: map[string]*dailyEntry{}},
	}
	old := serpapiHotels
	serpapiHotels = stub
	t.Cleanup(func() { serpapiHotels = old })
	t.Setenv("SERPAPI_API_KEY", "test-serpapi-key")
}

// swapLodgingStub points the shared Places singleton at a fixed Text Search
// body — the discovery tier's upstream.
func swapLodgingStub(t *testing.T, body string) *countingTransport {
	t.Helper()
	svc, rt := placesDouble(t, body)
	prev := placesService
	placesService = svc
	t.Cleanup(func() { placesService = prev })
	return rt
}

// failingLodging makes any discovery-tier call fail the test — proof that a
// code path stayed on the rates tier.
func failingLodging(t *testing.T) {
	t.Helper()
	svc, _ := placesDouble(t, `{"status":"OK","results":[]}`)
	svc.Client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Errorf("unexpected Google Places request: discovery tier should not have run")
		return nil, context.Canceled
	})}
	prev := placesService
	placesService = svc
	t.Cleanup(func() { placesService = prev })
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

const athensHotelsJSON = `{"properties":[
 {"name":"Moxy Athens City","type":"hotel","link":"https://marriott.com/x",
  "extracted_hotel_class":3,"overall_rating":4.5333333,"reviews":1255,
  "gps_coordinates":{"latitude":37.98,"longitude":23.72},
  "rate_per_night":{"lowest":"€154","extracted_lowest":154},
  "total_rate":{"lowest":"€614","extracted_lowest":614},
  "amenities":["Free Wi-Fi","Bar"],"check_in_time":"3:00 PM","check_out_time":"11:00 AM",
  "images":[{"thumbnail":"https://lh3.googleusercontent.com/x"}]},
 {"name":"Duplex with terrace","type":"vacation rental",
  "overall_rating":4.68,"reviews":132,
  "rate_per_night":{"lowest":"€133","extracted_lowest":133},
  "total_rate":{"lowest":"€532","extracted_lowest":532},
  "images":[{"thumbnail":"https://lh3.googleusercontent.com/y"}]},
 {"name":"Grand Hyatt Athens","type":"hotel","extracted_hotel_class":5,
  "overall_rating":4.3,"reviews":7110,
  "rate_per_night":{"lowest":"€294","extracted_lowest":294},
  "total_rate":{"lowest":"€1174","extracted_lowest":1174},
  "images":[{"thumbnail":"https://lh3.googleusercontent.com/z"}]}
]}`

const athensLodgingJSON = `{"status":"OK","results":[
 {"place_id":"p1","name":"Hotel Grande Bretagne","formatted_address":"Syntagma, Athens",
  "geometry":{"location":{"lat":37.97,"lng":23.73}},"types":["lodging"],
  "rating":4.8,"user_ratings_total":6749,
  "photos":[{"photo_reference":"ref-gb","html_attributions":["<a>Someone</a>"]}]},
 {"place_id":"p2","name":"Athens Capital Hotel","formatted_address":"Athens",
  "geometry":{"location":{"lat":37.98,"lng":23.73}},"types":["lodging"],
  "rating":4.2,"user_ratings_total":2186}
]}`

func datedReq() HotelSearchRequest {
	return HotelSearchRequest{City: "Athens", CheckIn: "2026-09-03", CheckOut: "2026-09-07", Adults: 2}
}

// --- tests -----------------------------------------------------------------

// The mapping is the load-bearing surface: prices must survive as numbers with
// a currency beside them, ratings must be rounded once here rather than in
// every renderer, and the booking link must be OUR affiliate builder rather
// than the provider's (unmonetized) property link.
func TestHotelSearchMapping(t *testing.T) {
	var got map[string][]string
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.Query()
		w.Write([]byte(athensHotelsJSON))
	})
	failingLodging(t)

	res, err := searchHotels(context.Background(), datedReq())
	if err != nil {
		t.Fatalf("searchHotels: %v", err)
	}
	if !res.RatesLive {
		t.Fatalf("expected rates_live on a dated search, note=%q", res.RatesNote)
	}
	if len(res.Stays) != 3 {
		t.Fatalf("want 3 stays, got %d", len(res.Stays))
	}

	// Request shape: the engine requires both dates, and the point of sale is
	// pinned so prices cannot drift with geo inference.
	for k, want := range map[string]string{
		"engine": "google_hotels", "q": "Athens",
		"check_in_date": "2026-09-03", "check_out_date": "2026-09-07",
		"adults": "2", "currency": "USD", "gl": "us", "hl": "en",
	} {
		if len(got[k]) == 0 || got[k][0] != want {
			t.Errorf("query %s = %v, want %q", k, got[k], want)
		}
	}

	m := res.Stays[0]
	if m.Name != "Moxy Athens City" || m.Kind != "hotel" {
		t.Errorf("first stay = %q/%q", m.Name, m.Kind)
	}
	if m.RatePerNight == nil || *m.RatePerNight != 154 {
		t.Errorf("rate_per_night = %v, want 154", m.RatePerNight)
	}
	if m.TotalRate == nil || *m.TotalRate != 614 {
		t.Errorf("total_rate = %v, want 614", m.TotalRate)
	}
	// Price and currency are inseparable — a number nobody can compare is
	// worse than no number (same rule as booking_options, 00065).
	if m.Currency == nil || *m.Currency != "USD" {
		t.Errorf("currency = %v, want USD", m.Currency)
	}
	if m.StarClass == nil || *m.StarClass != 3 {
		t.Errorf("star_class = %v, want 3", m.StarClass)
	}
	// 4.5333333 must arrive as 4.5, rounded once at the boundary.
	if m.Rating == nil || *m.Rating != 4.5 {
		t.Errorf("rating = %v, want 4.5", m.Rating)
	}
	if m.Reviews == nil || *m.Reviews != 1255 {
		t.Errorf("reviews = %v, want 1255", m.Reviews)
	}
	if m.Latitude == nil || m.Longitude == nil {
		t.Errorf("coordinates dropped")
	}
	if m.ImageURL != "https://lh3.googleusercontent.com/x" {
		t.Errorf("image_url = %q", m.ImageURL)
	}
	if m.PhotoRef != "" {
		t.Errorf("rates tier must not set photo_ref (its images are not Place Photos): %q", m.PhotoRef)
	}
	// The provider's own `link` is the property's website and earns nothing;
	// the handoff has to be the affiliate-carrying Booking.com builder.
	if !strings.Contains(m.BookingURL, "booking.com") {
		t.Errorf("booking_url = %q, want a booking.com affiliate link", m.BookingURL)
	}
	if !strings.Contains(m.BookingURL, "checkin=2026-09-03") {
		t.Errorf("booking_url lost the dates: %q", m.BookingURL)
	}

	if res.Stays[1].Kind != "vacation_rental" {
		t.Errorf("vacation rental not distinguished: %q", res.Stays[1].Kind)
	}
}

// A dateless ask must not cost an upstream rate call at all: the engine
// rejects it outright, so discovering that upstream would burn a request from
// a 250/month allowance to learn something already known.
func TestHotelSearchWithoutDatesNeverCallsRatesProvider(t *testing.T) {
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("unexpected rates request for a dateless search: %s", r.URL.RawQuery)
		w.Write([]byte(athensHotelsJSON))
	})
	swapLodgingStub(t, athensLodgingJSON)

	res, err := searchHotels(context.Background(), HotelSearchRequest{City: "Athens"})
	if err != nil {
		t.Fatalf("searchHotels: %v", err)
	}
	if res.RatesLive {
		t.Fatal("dateless search must not claim live rates")
	}
	if res.RatesNote != "no_dates" {
		t.Errorf("rates_note = %q, want no_dates", res.RatesNote)
	}
	if len(res.Stays) != 2 {
		t.Fatalf("want 2 discovery stays, got %d", len(res.Stays))
	}
	gb := res.Stays[0]
	if gb.Name != "Hotel Grande Bretagne" {
		t.Errorf("name = %q", gb.Name)
	}
	if gb.Reviews == nil || *gb.Reviews != 6749 {
		t.Errorf("review count dropped: %v", gb.Reviews)
	}
	// The whole point of the tier boundary: no price may appear anywhere.
	if gb.RatePerNight != nil || gb.TotalRate != nil || gb.Currency != nil {
		t.Errorf("discovery tier leaked a price: %+v", gb)
	}
	// Discovery images are billed Place Photos, so they ride as a ref for the
	// client to exchange through /places/photo — never as a bare URL.
	if gb.PhotoRef != "ref-gb" || gb.ImageURL != "" {
		t.Errorf("photo handling wrong: ref=%q url=%q", gb.PhotoRef, gb.ImageURL)
	}
	if !placesService.photoRefAllowed("ref-gb") {
		t.Error("emitted photo ref was not registered with the /places/photo gate")
	}
}

// Quota exhaustion is a degrade, not an error — and it must never be reported
// as live rates.
func TestHotelQuotaExhaustionDegradesToDiscovery(t *testing.T) {
	var upstream atomic.Int32
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) {
		upstream.Add(1)
		w.Write([]byte(athensHotelsJSON))
	})
	swapLodgingStub(t, athensLodgingJSON)
	t.Setenv("SERPAPI_HOTEL_SEARCHES_PER_DAY", "0")

	res, err := searchHotels(context.Background(), datedReq())
	if err != nil {
		t.Fatalf("searchHotels: %v", err)
	}
	if got := upstream.Load(); got != 0 {
		t.Errorf("burned %d upstream searches with the cap at 0", got)
	}
	if res.RatesLive || res.RatesNote != "quota" {
		t.Errorf("rates_live=%v note=%q, want false/quota", res.RatesLive, res.RatesNote)
	}
	if len(res.Stays) == 0 {
		t.Error("degrade produced nothing; the tool would look broken")
	}
}

// The hotel cap must be its own counter. A shared one would let a
// hotel-heavy planning session take flight search down with it — the exact
// failure the separate key exists to prevent.
func TestHotelQuotaDoesNotStarveFlights(t *testing.T) {
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(athensHotelsJSON)) })
	swapLodgingStub(t, athensLodgingJSON)
	t.Setenv("SERPAPI_HOTEL_SEARCHES_PER_DAY", "1")
	t.Setenv("SERPAPI_SEARCHES_PER_DAY", "50")

	for i := 0; i < 3; i++ {
		req := datedReq()
		req.City = []string{"Athens", "Rome", "Lisbon"}[i] // distinct cache keys
		searchHotels(context.Background(), req)
	}

	if got := serpapiHotels.RemainingToday(); got != 0 {
		t.Errorf("hotel headroom = %d, want 0 after exceeding the cap", got)
	}
	// The flights counter is untouched by any of that.
	if got := serpapiFlights.RemainingToday(); got != 50 {
		t.Errorf("flight headroom = %d, want 50 — hotels ate the flights allowance", got)
	}
}

// A provider outage degrades rather than erroring, and says which reason.
func TestHotelProviderOutageDegrades(t *testing.T) {
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"boom"}`, http.StatusInternalServerError)
	})
	swapLodgingStub(t, athensLodgingJSON)

	res, err := searchHotels(context.Background(), datedReq())
	if err != nil {
		t.Fatalf("outage must not surface as an error: %v", err)
	}
	if res.RatesLive || res.RatesNote != "unavailable" {
		t.Errorf("rates_live=%v note=%q, want false/unavailable", res.RatesLive, res.RatesNote)
	}
	if len(res.Stays) == 0 {
		t.Error("no fallback results")
	}
}

// Cache hits are free: a repeat search must neither hit the upstream nor
// consume a slot from the daily cap.
func TestHotelCacheHitBurnsNoQuota(t *testing.T) {
	var upstream atomic.Int32
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) {
		upstream.Add(1)
		w.Write([]byte(athensHotelsJSON))
	})
	failingLodging(t)
	t.Setenv("SERPAPI_HOTEL_SEARCHES_PER_DAY", "5")

	for i := 0; i < 3; i++ {
		if _, err := searchHotels(context.Background(), datedReq()); err != nil {
			t.Fatalf("search %d: %v", i, err)
		}
	}
	if got := upstream.Load(); got != 1 {
		t.Errorf("upstream calls = %d, want 1", got)
	}
	if got := serpapiHotels.RemainingToday(); got != 4 {
		t.Errorf("headroom = %d, want 4 (cache hits are free)", got)
	}
}

// DIVERGENCE from the flights service, which caches empty results on purpose.
// An empty ROUTE is a real answer; an empty CITY is not — every city has
// hotels, so zero properties means a bad city string or an upstream hiccup,
// and caching that for six hours would poison the city for the session.
func TestHotelEmptyResultIsNotCached(t *testing.T) {
	var upstream atomic.Int32
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) {
		upstream.Add(1)
		w.Write([]byte(`{"properties":[]}`))
	})
	swapLodgingStub(t, `{"status":"OK","results":[]}`)
	t.Setenv("SERPAPI_HOTEL_SEARCHES_PER_DAY", "5")

	for i := 0; i < 2; i++ {
		searchHotels(context.Background(), datedReq())
	}
	if got := upstream.Load(); got != 2 {
		t.Errorf("upstream calls = %d, want 2 — an empty city must not be cached", got)
	}
}

// The key rides in the query string, so BOTH error paths must redact it: the
// request-build path (a malformed base URL yields a *url.Error quoting the
// whole raw URL) and the Do path. The build-path leak was a real review
// finding on the flights seam.
func TestHotelKeyNeverInErrors(t *testing.T) {
	const key = "super-secret-hotel-key"

	t.Run("do path", func(t *testing.T) {
		srv := httptest.NewServer(nil)
		srv.Close() // closed: Do fails with a *url.Error carrying the URL
		svc := &SerpapiHotelsService{
			BaseURL: srv.URL, Client: &http.Client{Timeout: time.Second},
			cache: newTTLCache[[]HotelStay](time.Hour, 10),
			daily: &dailyCounter{entries: map[string]*dailyEntry{}},
		}
		t.Setenv("SERPAPI_API_KEY", key)
		_, err := svc.SearchStays(context.Background(), datedReq())
		if err == nil {
			t.Fatal("want an error from a closed server")
		}
		if strings.Contains(err.Error(), key) {
			t.Fatalf("API key leaked into error: %v", err)
		}
	})

	t.Run("build path", func(t *testing.T) {
		svc := &SerpapiHotelsService{
			BaseURL: "://not-a-url", Client: &http.Client{Timeout: time.Second},
			cache: newTTLCache[[]HotelStay](time.Hour, 10),
			daily: &dailyCounter{entries: map[string]*dailyEntry{}},
		}
		t.Setenv("SERPAPI_API_KEY", key)
		_, err := svc.SearchStays(context.Background(), datedReq())
		if err == nil {
			t.Fatal("want an error from a malformed base URL")
		}
		if strings.Contains(err.Error(), key) {
			t.Fatalf("API key leaked into error: %v", err)
		}
	})
}

// A rates-tier row with no price is dropped rather than rendered blank beside
// priced neighbours, where it would read as "free".
func TestHotelPricelessRowsDropped(t *testing.T) {
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"properties":[
			{"name":"No Price Inn","type":"hotel","overall_rating":4.1},
			{"name":"Priced Hotel","type":"hotel","overall_rating":4.2,
			 "rate_per_night":{"extracted_lowest":120}},
			{"name":"","type":"hotel","rate_per_night":{"extracted_lowest":99}}
		]}`))
	})
	failingLodging(t)

	res, _ := searchHotels(context.Background(), datedReq())
	if len(res.Stays) != 1 || res.Stays[0].Name != "Priced Hotel" {
		t.Fatalf("want only the priced, named row; got %+v", res.Stays)
	}
}

// Filters must actually filter, because the tool schema promises them to the
// model — a silently-dropped ceiling becomes a budget claim we never applied.
func TestHotelFiltersApply(t *testing.T) {
	swapHotelStub(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(athensHotelsJSON)) })
	failingLodging(t)

	req := datedReq()
	req.MaxPrice = 200
	res, _ := searchHotels(context.Background(), req)
	for _, s := range res.Stays {
		if *s.RatePerNight > 200 {
			t.Errorf("%s at %v exceeds the max_price ceiling", s.Name, *s.RatePerNight)
		}
	}
	if len(res.Stays) != 2 {
		t.Errorf("want 2 stays under 200, got %d", len(res.Stays))
	}

	req2 := datedReq()
	req2.MinRating = 4.6
	res2, _ := searchHotels(context.Background(), req2)
	if len(res2.Stays) != 1 || res2.Stays[0].Name != "Duplex with terrace" {
		t.Errorf("min_rating not applied: %+v", res2.Stays)
	}
}

// The summarizer is what stops the model inventing a nightly rate it was
// never given. A no-rates result looks exactly like a rates result with the
// numbers omitted, so the prohibition has to be explicit, not implied.
func TestSummarizeHotelsStatesWhichTierAnswered(t *testing.T) {
	usd := "USD"
	rate, total, rating := 154.0, 614.0, 4.5
	reviews, stars := 1255, 3
	live := HotelSearchResult{
		City: "Athens", CheckIn: "2026-09-03", CheckOut: "2026-09-07", RatesLive: true,
		Stays: []HotelStay{{Name: "Moxy Athens City", Kind: "hotel", StarClass: &stars,
			Rating: &rating, Reviews: &reviews, RatePerNight: &rate, TotalRate: &total, Currency: &usd}},
	}
	live.Adults = 2
	got := summarizeHotels(live)
	// The party the price covers must be stated in the same breath as the
	// price. An unlabeled party total reading as a per-person fare is the
	// exact bug this repo already shipped once on flights.
	for _, want := range []string{"2 guests", "PER NIGHT for the whole party of 2",
		"live prices", "USD", "154", "614", "4.5", "1255", "add_accommodation"} {
		if !strings.Contains(got, want) {
			t.Errorf("rates summary missing %q:\n%s", want, got)
		}
	}

	discovery := HotelSearchResult{
		City: "Athens", RatesNote: "no_dates",
		Stays: []HotelStay{{Name: "Hotel Grande Bretagne", Kind: "hotel", Rating: &rating}},
	}
	got = summarizeHotels(discovery)
	if !strings.Contains(got, "PRICES WERE NOT CHECKED") {
		t.Errorf("discovery summary must say prices were not checked:\n%s", got)
	}
	if !strings.Contains(got, "Do not state, estimate, or imply a nightly price") {
		t.Errorf("discovery summary must forbid inventing a price:\n%s", got)
	}
	if !strings.Contains(got, "no check-in/check-out dates were given") {
		t.Errorf("discovery summary must say WHY there are no prices:\n%s", got)
	}
	// A number a traveler could mistake for a rate must not appear at all.
	if strings.Contains(got, "/night") {
		t.Errorf("discovery summary leaked a rate:\n%s", got)
	}
}

func TestSummarizeHotelsEmpty(t *testing.T) {
	if got := summarizeHotels(HotelSearchResult{City: "Nowhere"}); !strings.Contains(got, "No stays found") {
		t.Errorf("empty summary = %q", got)
	}
}

// The kill switch has to mean what it says. envInt treats any non-positive
// value as "unset", so routing this knob through it would turn an operator's
// deliberate `SERPAPI_HOTEL_SEARCHES_PER_DAY=0` into the default cap — rate
// lookups they thought they had switched OFF, spending from a shared 250/mo
// key they cannot unset (flights needs it too).
func TestHotelDailyCapZeroMeansZero(t *testing.T) {
	for _, tc := range []struct {
		set  bool
		val  string
		want int
	}{
		{false, "", defaultHotelSearchesPerDay},
		{true, "", defaultHotelSearchesPerDay},
		{true, "not-a-number", defaultHotelSearchesPerDay},
		{true, "0", 0},
		{true, "-5", 0},
		{true, "3", 3},
	} {
		func() {
			if tc.set {
				t.Setenv("SERPAPI_HOTEL_SEARCHES_PER_DAY", tc.val)
			} else {
				t.Setenv("SERPAPI_HOTEL_SEARCHES_PER_DAY", "")
				os.Unsetenv("SERPAPI_HOTEL_SEARCHES_PER_DAY")
			}
			if got := hotelSearchesPerDay(); got != tc.want {
				t.Errorf("set=%v val=%q: cap = %d, want %d", tc.set, tc.val, got, tc.want)
			}
		}()
	}
}
