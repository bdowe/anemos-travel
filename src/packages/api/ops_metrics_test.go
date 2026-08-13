package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/mux"
)

// newOpsRegistry builds an isolated registry so tests never race on the
// package-global opsMetrics (which the shared testRouter mutates on every
// request). record/snapshot are methods on *opsRegistry, so a fresh one gets
// the same behavior without cross-test contamination.
func newOpsRegistry() *opsRegistry {
	return &opsRegistry{routes: make(map[string]*routeStat)}
}

// TestOpsRegistryConcurrentRecord hammers record from many goroutines and
// asserts the total count is exact. Run under -race, this proves the registry
// is data-race free and loses no increments.
func TestOpsRegistryConcurrentRecord(t *testing.T) {
	reg := newOpsRegistry()
	const goroutines = 50
	const perG = 200

	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < perG; i++ {
				// Two templates so we also exercise concurrent creation of a
				// route's stat under the write lock.
				tmpl := "/api/v1/a"
				if i%2 == 0 {
					tmpl = "/api/v1/b"
				}
				reg.record("GET", tmpl, 200, time.Millisecond)
			}
		}(g)
	}
	wg.Wait()

	snap := reg.snapshot()
	want := uint64(goroutines * perG)
	if snap.Requests.Total != want {
		t.Fatalf("total = %d, want %d", snap.Requests.Total, want)
	}
	if snap.Requests.ByClass["2xx"] != want {
		t.Fatalf("2xx = %d, want %d", snap.Requests.ByClass["2xx"], want)
	}
	var routeSum uint64
	for _, r := range snap.Requests.Routes {
		routeSum += r.Count
	}
	if routeSum != want {
		t.Fatalf("route count sum = %d, want %d", routeSum, want)
	}
}

// TestOpsPercentiles feeds a known latency distribution and asserts p50/p95/p99
// land in the right histogram buckets (bucket-granular, so we assert the
// reported upper edge). 100 requests: 90 fast (~1ms → bucket 5), 9 mid (~120ms
// → bucket 250), 1 slow (~3000ms → bucket 5000).
func TestOpsPercentiles(t *testing.T) {
	reg := newOpsRegistry()
	for i := 0; i < 90; i++ {
		reg.record("GET", "/x", 200, 1*time.Millisecond)
	}
	for i := 0; i < 9; i++ {
		reg.record("GET", "/x", 200, 120*time.Millisecond)
	}
	reg.record("GET", "/x", 200, 3000*time.Millisecond)

	snap := reg.snapshot()
	if len(snap.Requests.Routes) != 1 {
		t.Fatalf("routes = %d, want 1", len(snap.Requests.Routes))
	}
	r := snap.Requests.Routes[0]
	// p50 sits among the 90 fast requests → 5ms bucket.
	if r.P50Ms != 5 {
		t.Errorf("p50 = %v, want 5 (fast bucket)", r.P50Ms)
	}
	// p95 is the 95th observation: past the 90 fast into the mid group → 250ms.
	if r.P95Ms != 250 {
		t.Errorf("p95 = %v, want 250 (mid bucket)", r.P95Ms)
	}
	// p99 is the 99th observation: still the last mid request → 250ms.
	if r.P99Ms != 250 {
		t.Errorf("p99 = %v, want 250 (mid bucket)", r.P99Ms)
	}
	// Mean is dominated by the single 3s outlier: (90*1 + 9*120 + 3000)/100.
	wantMean := float64(90*1+9*120+3000) / 100.0
	if r.MeanMs < wantMean-0.5 || r.MeanMs > wantMean+0.5 {
		t.Errorf("mean = %v, want ~%v", r.MeanMs, wantMean)
	}
}

// TestOpsTemplateGrouping asserts two requests to the SAME template but
// different concrete ids collapse into one route row with count 2.
func TestOpsTemplateGrouping(t *testing.T) {
	reg := newOpsRegistry()
	reg.record("GET", "/api/v1/trips/{id}", 200, time.Millisecond)
	reg.record("GET", "/api/v1/trips/{id}", 200, time.Millisecond)

	snap := reg.snapshot()
	if len(snap.Requests.Routes) != 1 {
		t.Fatalf("routes = %d, want 1 (templates must collapse)", len(snap.Requests.Routes))
	}
	r := snap.Requests.Routes[0]
	if r.Route != "/api/v1/trips/{id}" || r.Count != 2 {
		t.Fatalf("route = %q count = %d, want /api/v1/trips/{id} count 2", r.Route, r.Count)
	}
}

// TestOpsErrorRate feeds a mix of 2xx and 5xx and asserts the class buckets and
// error_rate. 4xx and 5xx both count toward errors.
func TestOpsErrorRate(t *testing.T) {
	reg := newOpsRegistry()
	for i := 0; i < 7; i++ {
		reg.record("GET", "/y", 200, time.Millisecond)
	}
	reg.record("GET", "/y", 404, time.Millisecond)
	reg.record("GET", "/y", 500, time.Millisecond)
	reg.record("GET", "/y", 503, time.Millisecond)

	snap := reg.snapshot()
	r := snap.Requests.Routes[0]
	if r.ByClass["2xx"] != 7 || r.ByClass["4xx"] != 1 || r.ByClass["5xx"] != 2 {
		t.Fatalf("by_class = %v, want 2xx:7 4xx:1 5xx:2", r.ByClass)
	}
	// (1 + 2) / 10 = 0.3
	if r.ErrorRate < 0.29 || r.ErrorRate > 0.31 {
		t.Errorf("error_rate = %v, want ~0.3", r.ErrorRate)
	}
}

// TestMetricsMiddlewareRecords drives the middleware over a tiny mux with a
// handler that 500s, and asserts the 5xx class + error_rate land in the shared
// opsMetrics registry under the matched route template.
func TestMetricsMiddlewareRecords(t *testing.T) {
	// Isolate from other tests by swapping the package global for the duration.
	saved := opsMetrics
	opsMetrics = newOpsRegistry()
	defer func() { opsMetrics = saved }()

	router := mux.NewRouter()
	router.Use(metricsMiddleware)
	router.HandleFunc("/things/{id}", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}).Methods("GET")

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest("GET", "/things/42", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}

	snap := opsMetrics.snapshot()
	if snap.Requests.Total != 1 {
		t.Fatalf("total = %d, want 1", snap.Requests.Total)
	}
	r := snap.Requests.Routes[0]
	if r.Route != "/things/{id}" {
		t.Errorf("route = %q, want /things/{id} (template, not concrete id)", r.Route)
	}
	if r.ByClass["5xx"] != 1 {
		t.Errorf("5xx = %d, want 1", r.ByClass["5xx"])
	}
	if r.ErrorRate != 1 {
		t.Errorf("error_rate = %v, want 1", r.ErrorRate)
	}
}

// TestMetricsMiddlewareNoRouteGroupsAsOther asserts a request the router never
// matched (no mux route on the context) records under "other".
func TestMetricsMiddlewareNoRouteGroupsAsOther(t *testing.T) {
	saved := opsMetrics
	opsMetrics = newOpsRegistry()
	defer func() { opsMetrics = saved }()

	// Wrap the middleware directly (not via a mux) so CurrentRoute(r) is nil.
	h := metricsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/whatever", nil))

	snap := opsMetrics.snapshot()
	if len(snap.Requests.Routes) != 1 || snap.Requests.Routes[0].Route != "other" {
		t.Fatalf("routes = %v, want a single 'other' row", snap.Requests.Routes)
	}
	if snap.Requests.Routes[0].ByClass["4xx"] != 1 {
		t.Errorf("4xx = %d, want 1", snap.Requests.Routes[0].ByClass["4xx"])
	}
}

// TestOpsProcessStats asserts the process section is populated (uptime,
// goroutines, GOMAXPROCS, started_at) — the part that must render even without
// a DB.
func TestOpsProcessStats(t *testing.T) {
	snap := newOpsRegistry().snapshot()
	if snap.Process.Goroutines < 1 {
		t.Errorf("goroutines = %d, want >= 1", snap.Process.Goroutines)
	}
	if snap.Process.GOMAXPROCS < 1 {
		t.Errorf("gomaxprocs = %d, want >= 1", snap.Process.GOMAXPROCS)
	}
	if snap.Process.StartedAt == "" {
		t.Errorf("started_at empty, want a timestamp")
	}
	if snap.Process.UptimeS < 0 {
		t.Errorf("uptime = %d, want >= 0", snap.Process.UptimeS)
	}
	if snap.Upstream == nil {
		t.Errorf("upstream map is nil, want present (possibly empty)")
	}
}

// The AI-health counters (ai_health.go) surface in the flattened upstream map.
func TestUpstreamCountsIncludeAIHealth(t *testing.T) {
	resetAIHealth(t)
	recordAIResult(nil)                      // success
	recordAIResult(context.DeadlineExceeded) // transient
	m := upstreamCountsSnapshot()
	if m["ai_success_total"] != 1 || m["ai_transient_total"] != 1 {
		t.Fatalf("ai counters = success %d transient %d, want 1/1",
			m["ai_success_total"], m["ai_transient_total"])
	}
	if _, ok := m["ai_fatal_total"]; !ok {
		t.Fatalf("ai_fatal_total missing from upstream map: %v", m)
	}
	if _, ok := m["ai_consecutive_fatal"]; !ok {
		t.Fatalf("ai_consecutive_fatal missing from upstream map: %v", m)
	}
}

func TestUpstreamCountsIncludeRateLimitedTotal(t *testing.T) {
	before := upstreamCountsSnapshot()["rate_limited_total"]
	rateLimited429s.Add(1)
	if after := upstreamCountsSnapshot()["rate_limited_total"]; after != before+1 {
		t.Fatalf("rate_limited_total = %d then %d, want +1", before, after)
	}
}

// Shed 503s must be visible in ops metrics: buildRouter registers
// metricsMiddleware BEFORE the concurrency shedder, so a request rejected by
// the semaphore is still timed and recorded. This mirrors that order.
func TestShed503IsRecordedByMetricsMiddleware(t *testing.T) {
	router := mux.NewRouter()
	router.Use(metricsMiddleware)
	router.Use(newConcurrencyLimiter(1).middleware)
	entered := make(chan struct{})
	release := make(chan struct{})
	parked := make(chan struct{})
	router.HandleFunc("/api/v1/busy", func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		<-release
		w.WriteHeader(http.StatusOK)
	})

	// Occupy the single slot with a request parked inside the handler.
	go func() {
		defer close(parked)
		router.ServeHTTP(httptest.NewRecorder(),
			httptest.NewRequest(http.MethodGet, "/api/v1/busy", nil))
	}()
	<-entered

	before := opsMetrics.snapshot().Requests.ByClass["5xx"]
	shed := httptest.NewRecorder()
	router.ServeHTTP(shed, httptest.NewRequest(http.MethodGet, "/api/v1/busy", nil))
	if shed.Code != http.StatusServiceUnavailable {
		t.Fatalf("second request = %d, want 503", shed.Code)
	}
	if after := opsMetrics.snapshot().Requests.ByClass["5xx"]; after != before+1 {
		t.Fatalf("5xx count = %d then %d; the shed 503 must be recorded", before, after)
	}
	close(release)
	<-parked
}

// TestOpsMetricsEndpoint is the DB-backed admin auth path: an admin token gets
// 200 + the expected shape; a non-admin gets 403.
func TestOpsMetricsEndpoint(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "ops-admin@example.com")
	makeAdmin(t, admin.ID)
	_, userToken := createTestUser(t, "ops-user@example.com")

	// Non-admin is forbidden.
	if rec := doJSON(t, "GET", "/api/v1/admin/ops/metrics", userToken, nil); rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin = %d, want 403", rec.Code)
	}
	// Anonymous is unauthorized.
	if rec := doJSON(t, "GET", "/api/v1/admin/ops/metrics", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous = %d, want 401", rec.Code)
	}

	rec := doJSON(t, "GET", "/api/v1/admin/ops/metrics", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("admin = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	proc, ok := body["process"].(map[string]any)
	if !ok {
		t.Fatalf("process missing: %v", body["process"])
	}
	if _, ok := proc["goroutines"].(float64); !ok {
		t.Errorf("process.goroutines missing/not a number: %v", proc["goroutines"])
	}
	if _, ok := proc["started_at"].(string); !ok {
		t.Errorf("process.started_at missing: %v", proc["started_at"])
	}
	reqs, ok := body["requests"].(map[string]any)
	if !ok {
		t.Fatalf("requests missing: %v", body["requests"])
	}
	// This very request flows through metricsMiddleware, so the endpoint's own
	// route template must already be counted.
	routes, _ := reqs["routes"].([]any)
	foundSelf := false
	for _, ri := range routes {
		if r, ok := ri.(map[string]any); ok && r["route"] == "/api/v1/admin/ops/metrics" {
			foundSelf = true
		}
	}
	if !foundSelf {
		t.Errorf("routes does not include the ops endpoint's own template; got %v", routes)
	}
	if _, ok := body["upstream"].(map[string]any); !ok {
		t.Errorf("upstream missing: %v", body["upstream"])
	}
}
