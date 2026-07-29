package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// countingTransport serves a canned JSON body and counts round trips, so tests
// can assert how many billable Google calls a code path would make.
type countingTransport struct {
	calls int
	body  string
}

func (c *countingTransport) RoundTrip(*http.Request) (*http.Response, error) {
	c.calls++
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(c.body)),
	}, nil
}

const fakeTextSearchJSON = `{"status":"OK","results":[{"place_id":"p1","name":"Louvre Museum","formatted_address":"Paris","geometry":{"location":{"lat":48.86,"lng":2.34}},"types":["museum"]}]}`

const fakePlaceDetailsJSON = `{"status":"OK","result":{"place_id":"p1","name":"Louvre Museum","formatted_address":"Paris","geometry":{"location":{"lat":48.86,"lng":2.34}},"types":["museum"]}}`

// The whole point of the placesService singleton is that the TTL caches
// survive across calls: identical searches must hit Google exactly once.
func TestSearchPlacesServedFromCache(t *testing.T) {
	rt := &countingTransport{body: fakeTextSearchJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}

	first, err := svc.SearchPlaces(context.Background(), "Louvre Museum Paris")
	if err != nil {
		t.Fatalf("first search failed: %v", err)
	}
	// Same query modulo case/whitespace must hit the cache, not Google.
	second, err := svc.SearchPlaces(context.Background(), "  louvre museum paris ")
	if err != nil {
		t.Fatalf("second search failed: %v", err)
	}

	if rt.calls != 1 {
		t.Fatalf("Google called %d times, want 1 (second lookup must come from cache)", rt.calls)
	}
	if len(first) != 1 || len(second) != 1 || second[0].PlaceID != "p1" {
		t.Fatalf("cached result mismatch: first=%v second=%v", first, second)
	}

	// The COGS counters must mirror what actually happened: one billable
	// upstream call (the miss), one cache hit (no upstream increment).
	if got := svc.searchCalls.snapshot(); got.Upstream != 1 || got.CacheHits != 1 {
		t.Fatalf("search counters = %+v, want upstream=1 cache_hits=1", got)
	}
	if got := svc.autocompleteCalls.snapshot(); got.Upstream != 0 || got.CacheHits != 0 {
		t.Fatalf("autocomplete counters moved on a search-only path: %+v", got)
	}
}

func TestGetPlaceDetailsServedFromCache(t *testing.T) {
	rt := &countingTransport{body: fakePlaceDetailsJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}

	if _, err := svc.GetPlaceDetails(context.Background(), "p1"); err != nil {
		t.Fatalf("first details call failed: %v", err)
	}
	got, err := svc.GetPlaceDetails(context.Background(), "p1")
	if err != nil {
		t.Fatalf("second details call failed: %v", err)
	}
	if rt.calls != 1 {
		t.Fatalf("Google called %d times, want 1", rt.calls)
	}
	if got == nil || got.Name != "Louvre Museum" {
		t.Fatalf("cached details mismatch: %+v", got)
	}
	if c := svc.detailsCalls.snapshot(); c.Upstream != 1 || c.CacheHits != 1 {
		t.Fatalf("details counters = %+v, want upstream=1 cache_hits=1", c)
	}
}

const fakeAutocompleteJSON = `{"status":"OK","predictions":[{"place_id":"p1","description":"Louvre Museum, Paris","types":["museum"]}]}`

func TestAutocompleteCountersTrackMissAndHit(t *testing.T) {
	rt := &countingTransport{body: fakeAutocompleteJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}

	if _, err := svc.GetPlaceAutocomplete(context.Background(), "louvre"); err != nil {
		t.Fatalf("first autocomplete failed: %v", err)
	}
	if _, err := svc.GetPlaceAutocomplete(context.Background(), " LOUVRE "); err != nil {
		t.Fatalf("second autocomplete failed: %v", err)
	}
	if rt.calls != 1 {
		t.Fatalf("Google called %d times, want 1", rt.calls)
	}
	if c := svc.autocompleteCalls.snapshot(); c.Upstream != 1 || c.CacheHits != 1 {
		t.Fatalf("autocomplete counters = %+v, want upstream=1 cache_hits=1", c)
	}
}

// placesCallsSnapshot must price exactly the UPSTREAM counts (cache hits are
// free) with the per-class constants — the dashboard's est_places_cost_usd.
func TestPlacesCallsSnapshotPricing(t *testing.T) {
	svc := NewGooglePlacesService()
	svc.searchCalls.upstream.Add(1000)       // $32
	svc.searchCalls.cacheHits.Add(500)       // free
	svc.autocompleteCalls.upstream.Add(1000) // $2.83
	svc.detailsCalls.upstream.Add(1000)      // $17

	snap := placesCallsSnapshot(svc)
	if snap.Search.Upstream != 1000 || snap.Search.CacheHits != 500 {
		t.Fatalf("search snapshot = %+v", snap.Search)
	}
	want := 32.0 + 2.83 + 17.0
	if diff := snap.EstPlacesCostUSD - want; diff > 1e-9 || diff < -1e-9 {
		t.Fatalf("est_places_cost_usd = %v, want %v", snap.EstPlacesCostUSD, want)
	}
}

// Degraded mode: the process-wide singleton is constructed at init even when
// GOOGLE_PLACES_API_KEY is absent; methods must fail with a clear error, not
// panic, so the rest of the API stays healthy.
func TestPlacesServiceSingletonSafeWithoutKey(t *testing.T) {
	if placesService == nil {
		t.Fatal("placesService singleton is nil")
	}

	svc := NewGooglePlacesService()
	svc.APIKey = ""
	if _, err := svc.SearchPlaces(context.Background(), "anything"); err == nil || !strings.Contains(err.Error(), "not configured") {
		t.Fatalf("SearchPlaces without key: err = %v, want not-configured error", err)
	}
	if _, err := svc.GetPlaceAutocomplete(context.Background(), "any"); err == nil {
		t.Fatal("GetPlaceAutocomplete without key must error")
	}
	if _, err := svc.GetPlaceDetails(context.Background(), "p1"); err == nil {
		t.Fatal("GetPlaceDetails without key must error")
	}
}

// failingTransport fails every round trip at the transport level, the way a
// DNS failure / upstream outage / client timeout does. http.Client wraps such
// failures in a *url.Error whose string embeds the full request URL — query
// secrets included — which is exactly what redactTransportError must strip.
type failingTransport struct{}

func (failingTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errFakeTransport
}

var errFakeTransport = fmt.Errorf("dial tcp 1.2.3.4:443: connection refused")

// Transport-level failures must never put the Google key (sent as a `key=`
// query param) into the error chain: these errors are surfaced to /plan tool
// results and, pre-redaction, were echoed by public handlers.
func TestPlacesTransportErrorsOmitAPIKey(t *testing.T) {
	const secret = "SECRET-GOOGLE-KEY"
	svc := NewGooglePlacesService()
	svc.APIKey = secret
	svc.Client = &http.Client{Transport: failingTransport{}}

	svc.PhotoClient.Transport = failingTransport{}

	calls := []struct {
		name string
		call func() error
	}{
		{"SearchPlaces", func() error { _, err := svc.SearchPlaces(context.Background(), "louvre"); return err }},
		{"GetPlaceAutocomplete", func() error { _, err := svc.GetPlaceAutocomplete(context.Background(), "lou"); return err }},
		{"GetPlaceDetails", func() error { _, err := svc.GetPlaceDetails(context.Background(), "p1"); return err }},
		{"GetPlacePhotoRef", func() error { _, _, err := svc.GetPlacePhotoRef(context.Background(), "p1"); return err }},
		{"ResolvePhotoURL", func() error { _, err := svc.ResolvePhotoURL(context.Background(), "ref1", 400); return err }},
	}
	for _, c := range calls {
		err := c.call()
		if err == nil {
			t.Fatalf("%s: expected a transport error", c.name)
		}
		msg := err.Error()
		if strings.Contains(msg, secret) || strings.Contains(msg, "key=") {
			t.Fatalf("%s: error leaks the API key: %q", c.name, msg)
		}
		if !strings.Contains(msg, "connection refused") {
			t.Fatalf("%s: redaction lost the underlying cause: %q", c.name, msg)
		}
	}
}

const fakeTextSearchWithPhotoJSON = `{"status":"OK","results":[{"place_id":"p1","name":"Ta Karamanlidika","formatted_address":"Athens","geometry":{"location":{"lat":37.98,"lng":23.72}},"types":["restaurant"],"rating":4.6,"price_level":2,"photos":[{"photo_reference":"PHOTOREF-abc123","html_attributions":["<a href=\"https://maps.google.com/x\">Jane D</a>"]}]}]}`

// Photo refs must ride the struct into SSE cards but never serialize — the
// model-facing tool_result and the public /places/search response both
// json.Marshal []PlaceSearchResult, and refs are pure token/byte bloat there.
func TestSearchPlacesDecodesPhotoRefButNeverMarshalsIt(t *testing.T) {
	rt := &countingTransport{body: fakeTextSearchWithPhotoJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}

	results, err := svc.SearchPlaces(context.Background(), "athens food")
	if err != nil {
		t.Fatalf("search failed: %v", err)
	}
	if len(results) != 1 || results[0].PhotoRef != "PHOTOREF-abc123" {
		t.Fatalf("photo ref not decoded: %+v", results)
	}
	if got := results[0].PhotoAttribution; got != "Jane D" {
		t.Fatalf("attribution = %q, want stripped text %q", got, "Jane D")
	}

	b, _ := json.Marshal(results)
	if strings.Contains(string(b), "PHOTOREF-abc123") || strings.Contains(string(b), "photo_ref") {
		t.Fatalf("marshalled search results leak photo data: %s", b)
	}
}

const fakePhotoDetailsJSON = `{"status":"OK","result":{"photos":[{"photo_reference":"PHOTOREF-venue","html_attributions":["<a href=\"x\">Local Snapper</a>"]}]}}`

func TestGetPlacePhotoRefCachedIncludingNegative(t *testing.T) {
	rt := &countingTransport{body: fakePhotoDetailsJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}

	ref, attr, err := svc.GetPlacePhotoRef(context.Background(), "p1")
	if err != nil || ref != "PHOTOREF-venue" || attr != "Local Snapper" {
		t.Fatalf("photo ref lookup = (%q, %q, %v)", ref, attr, err)
	}
	// Resolving a ref must register it with the /places/photo gate.
	if !svc.photoRefAllowed("PHOTOREF-venue") {
		t.Fatal("resolved ref not registered with the known-ref gate")
	}
	if _, _, err := svc.GetPlacePhotoRef(context.Background(), "p1"); err != nil {
		t.Fatalf("second lookup failed: %v", err)
	}
	if rt.calls != 1 {
		t.Fatalf("Google called %d times, want 1 (second lookup must come from cache)", rt.calls)
	}
	if c := svc.photoLookupCalls.snapshot(); c.Upstream != 1 || c.CacheHits != 1 {
		t.Fatalf("photo lookup counters = %+v, want upstream=1 cache_hits=1", c)
	}

	// A venue with no photos caches the negative result: one billable call
	// per TTL, not one per chat turn.
	rt2 := &countingTransport{body: `{"status":"OK","result":{}}`}
	svc.Client = &http.Client{Transport: rt2}
	if ref, _, err := svc.GetPlacePhotoRef(context.Background(), "p2"); err != nil || ref != "" {
		t.Fatalf("photo-less venue = (%q, %v), want empty ref + nil error", ref, err)
	}
	if _, _, err := svc.GetPlacePhotoRef(context.Background(), "p2"); err != nil {
		t.Fatalf("second photo-less lookup failed: %v", err)
	}
	if rt2.calls != 1 {
		t.Fatalf("negative result not cached: %d upstream calls, want 1", rt2.calls)
	}
}

// A cache-served ref must re-arm the serving gate: the gate cache evicts
// independently (capacity), and a ref the server is about to emit has to stay
// servable by /places/photo.
func TestGetPlacePhotoRefCacheHitRearmsGate(t *testing.T) {
	rt := &countingTransport{body: fakePhotoDetailsJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}

	if _, _, err := svc.GetPlacePhotoRef(context.Background(), "p1"); err != nil {
		t.Fatalf("first lookup failed: %v", err)
	}
	// Simulate the gate entry being evicted while the ref cache survives.
	svc.knownPhotoRefs = newTTLCache[struct{}](24*time.Hour, 10000)
	if svc.photoRefAllowed("PHOTOREF-venue") {
		t.Fatal("test setup: gate should be empty after swap")
	}

	if ref, _, err := svc.GetPlacePhotoRef(context.Background(), "p1"); err != nil || ref != "PHOTOREF-venue" {
		t.Fatalf("cache-hit lookup = (%q, %v)", ref, err)
	}
	if rt.calls != 1 {
		t.Fatalf("cache-hit went upstream: %d calls", rt.calls)
	}
	if !svc.photoRefAllowed("PHOTOREF-venue") {
		t.Fatal("cache-served ref not re-registered with the gate")
	}
}

// Deterministic dead-end statuses (retired/invalid place_id) must be cached
// like photo-less venues — one billed call per TTL, not one per chat turn.
// Transient statuses stay uncached so they retry.
func TestGetPlacePhotoRefCachesPermanentNotFound(t *testing.T) {
	rt := &countingTransport{body: `{"status":"NOT_FOUND"}`}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}

	if ref, _, err := svc.GetPlacePhotoRef(context.Background(), "dead-id"); err != nil || ref != "" {
		t.Fatalf("NOT_FOUND lookup = (%q, %v), want empty ref + nil error", ref, err)
	}
	if _, _, err := svc.GetPlacePhotoRef(context.Background(), "dead-id"); err != nil {
		t.Fatalf("second lookup failed: %v", err)
	}
	if rt.calls != 1 {
		t.Fatalf("permanent NOT_FOUND not cached: %d upstream calls, want 1", rt.calls)
	}

	// OVER_QUERY_LIMIT is transient: error out, cache nothing, retry later.
	rt2 := &countingTransport{body: `{"status":"OVER_QUERY_LIMIT"}`}
	svc.Client = &http.Client{Transport: rt2}
	if _, _, err := svc.GetPlacePhotoRef(context.Background(), "throttled-id"); err == nil {
		t.Fatal("transient status must surface as an error")
	}
	if _, _, err := svc.GetPlacePhotoRef(context.Background(), "throttled-id"); err == nil {
		t.Fatal("transient status must not be cached")
	}
	if rt2.calls != 2 {
		t.Fatalf("transient status calls = %d, want 2 (uncached)", rt2.calls)
	}
}

// redirectTransport plays the Place Photo API: a 302 whose Location is the
// googleusercontent image URL. Records request URLs so tests can assert the
// maxwidth actually sent upstream.
type redirectTransport struct {
	calls    int
	lastURL  string
	location string
}

func (r *redirectTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	r.calls++
	r.lastURL = req.URL.String()
	return &http.Response{
		StatusCode: http.StatusFound,
		Header:     http.Header{"Location": []string{r.location}},
		Body:       io.NopCloser(strings.NewReader("")),
	}, nil
}

func TestResolvePhotoURLCapturesRedirectAndCaches(t *testing.T) {
	rt := &redirectTransport{location: "https://lh3.googleusercontent.com/img-abc"}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.PhotoClient.Transport = rt

	got, err := svc.ResolvePhotoURL(context.Background(), "ref1", 400)
	if err != nil || got != "https://lh3.googleusercontent.com/img-abc" {
		t.Fatalf("ResolvePhotoURL = (%q, %v)", got, err)
	}
	if !strings.Contains(rt.lastURL, "maxwidth=400") {
		t.Fatalf("upstream URL missing clamped width: %s", rt.lastURL)
	}
	if _, err := svc.ResolvePhotoURL(context.Background(), "ref1", 400); err != nil {
		t.Fatalf("second resolve failed: %v", err)
	}
	if rt.calls != 1 {
		t.Fatalf("Google called %d times, want 1 (ref|width must be cached)", rt.calls)
	}
	if c := svc.photoCalls.snapshot(); c.Upstream != 1 || c.CacheHits != 1 {
		t.Fatalf("photo counters = %+v, want upstream=1 cache_hits=1", c)
	}

	// A different width is a different cached variant.
	if _, err := svc.ResolvePhotoURL(context.Background(), "ref1", 800); err != nil {
		t.Fatalf("800px resolve failed: %v", err)
	}
	if rt.calls != 2 {
		t.Fatalf("width variant not fetched separately: %d calls", rt.calls)
	}
}

// notFoundTransport plays Google refusing a ref (expired/invalid) — the
// handler must be able to tell this apart from an outage.
type notFoundTransport struct{ status int }

func (n notFoundTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return &http.Response{
		StatusCode: n.status,
		Header:     http.Header{},
		Body:       io.NopCloser(strings.NewReader("bad ref")),
	}, nil
}

func TestResolvePhotoURLMapsUpstreamRejectionToNotFound(t *testing.T) {
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	for _, status := range []int{http.StatusBadRequest, http.StatusForbidden, http.StatusNotFound} {
		svc.PhotoClient.Transport = notFoundTransport{status: status}
		_, err := svc.ResolvePhotoURL(context.Background(), "bad-ref", 400)
		if !errors.Is(err, errPhotoNotFound) {
			t.Fatalf("status %d: err = %v, want errPhotoNotFound", status, err)
		}
	}
	// A 5xx is an outage, not a missing photo.
	svc.PhotoClient.Transport = notFoundTransport{status: http.StatusInternalServerError}
	if _, err := svc.ResolvePhotoURL(context.Background(), "ref", 400); err == nil || errors.Is(err, errPhotoNotFound) {
		t.Fatalf("5xx mapped wrong: %v", err)
	}
}

func TestStripHTMLTags(t *testing.T) {
	cases := []struct{ in, want string }{
		{`<a href="https://maps.google.com/contrib/1">Jane D</a>`, "Jane D"},
		{"plain text", "plain text"},
		{"", ""},
		{"<b>nested <i>tags</i></b>", "nested tags"},
		{"unclosed <a href=", "unclosed"},
	}
	for _, c := range cases {
		if got := stripHTMLTags(c.in); got != c.want {
			t.Errorf("stripHTMLTags(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
