package main

import (
	"math"
	"net/http"
	"runtime"
	"sort"
	"sync"
	"time"

	"github.com/gorilla/mux"
)

// In-process request-metrics registry. Per-request latency/status are already
// LOGGED (the slog "request" line in requestIDMiddleware) but never aggregated;
// this layer keeps a concurrent-safe rollup in memory so the admin ops endpoint
// can render live latency/error/throughput without a DB round trip.
//
// PROCESS-LIFETIME, like the upstreamCallCounters in places_service.go: every
// counter starts at zero on boot and resets on restart/deploy. Nothing here is
// persisted and there is no migration — this is operational telemetry, not
// audited analytics. The registry is read-only for the DB layer: the ops
// endpoint must render even in degraded mode (dbPool == nil), which is exactly
// when process visibility matters most.

// processStart is captured once at package init so the ops endpoint can report
// uptime. The server has no other single start-time var to reuse.
var processStart = time.Now()

// opsBucketBoundsMs are the fixed upper edges (inclusive) of the latency
// histogram, in milliseconds. A request of X ms lands in the first bucket whose
// bound is >= X; anything over the last bound lands in the implicit +Inf
// overflow bucket. Fixed buckets keep record() allocation-free and make
// percentiles a cheap cumulative walk. Keep this in sync with opsBucketCount.
var opsBucketBoundsMs = [...]float64{5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000}

// opsBucketCount is len(opsBucketBoundsMs)+1 — the finite buckets plus the
// +Inf overflow bucket. A const so routeStat can hold a fixed array.
const opsBucketCount = len(opsBucketBoundsMs) + 1

// bucketIndex returns the histogram bucket for a latency in ms: 0..len-1 for
// the finite buckets, len (the overflow +Inf bucket) for anything larger.
func bucketIndex(ms float64) int {
	for i, b := range opsBucketBoundsMs {
		if ms <= b {
			return i
		}
	}
	return len(opsBucketBoundsMs)
}

// routeStat is the rollup for one (method, route-template) pair. A single small
// mutex guards the whole struct; the critical section is a handful of adds, so
// contention is negligible even under load and the read side gets a consistent
// snapshot.
type routeStat struct {
	mu       sync.Mutex
	method   string
	template string
	count    uint64
	// byClass is indexed by HTTP status class (status/100): [1]=1xx .. [5]=5xx.
	// Index 0 is unused. 4xx/5xx are what error_rate keys off.
	byClass  [6]uint64
	sumMs    float64 // sum of latencies for the mean
	buckets  [opsBucketCount]uint64
	lastSeen int64 // unix millis of the most recent request
}

func (s *routeStat) record(status int, dur time.Duration) {
	ms := float64(dur.Nanoseconds()) / 1e6
	class := status / 100
	if class < 1 {
		class = 1
	}
	if class > 5 {
		class = 5
	}
	s.mu.Lock()
	s.count++
	s.byClass[class]++
	s.sumMs += ms
	s.buckets[bucketIndex(ms)]++
	s.lastSeen = time.Now().UnixMilli()
	s.mu.Unlock()
}

// opsRegistry is the package-global registry keyed by "METHOD template".
type opsRegistry struct {
	mu     sync.RWMutex
	routes map[string]*routeStat
}

// opsMetrics is the process-global request-metrics registry.
var opsMetrics = &opsRegistry{routes: make(map[string]*routeStat)}

// record folds one completed request into the registry. The common case (route
// already seen) takes only the read lock plus the per-route lock; the write
// lock is held just long enough to create a new route's stat once.
func (o *opsRegistry) record(method, template string, status int, dur time.Duration) {
	key := method + " " + template
	o.mu.RLock()
	s := o.routes[key]
	o.mu.RUnlock()
	if s == nil {
		o.mu.Lock()
		if s = o.routes[key]; s == nil {
			s = &routeStat{method: method, template: template}
			o.routes[key] = s
		}
		o.mu.Unlock()
	}
	s.record(status, dur)
}

// classLabel maps a status class (1..5) to its "Nxx" label.
func classLabel(class int) string {
	switch class {
	case 1:
		return "1xx"
	case 2:
		return "2xx"
	case 3:
		return "3xx"
	case 4:
		return "4xx"
	case 5:
		return "5xx"
	}
	return "other"
}

// percentileMs returns the pth-percentile latency (0<p<=1) from a histogram
// bucket snapshot, as the upper edge of the bucket the pth observation falls
// in. Overflow (+Inf) observations report the largest finite bound. Precision
// is bucket-granular by design.
func percentileMs(buckets *[opsBucketCount]uint64, count uint64, p float64) float64 {
	if count == 0 {
		return 0
	}
	target := uint64(math.Ceil(p * float64(count)))
	if target == 0 {
		target = 1
	}
	var cum uint64
	for i, c := range buckets {
		cum += c
		if cum >= target {
			if i < len(opsBucketBoundsMs) {
				return opsBucketBoundsMs[i]
			}
			return opsBucketBoundsMs[len(opsBucketBoundsMs)-1]
		}
	}
	return opsBucketBoundsMs[len(opsBucketBoundsMs)-1]
}

// ---- JSON view types (tags are the wire contract) ----

// OpsMetricsResponse is the body of GET /admin/ops/metrics.
type OpsMetricsResponse struct {
	Process  ProcessStats     `json:"process"`
	Requests RequestMetrics   `json:"requests"`
	Upstream map[string]int64 `json:"upstream"`
}

// ProcessStats is the live runtime snapshot (goroutines, heap, GOMAXPROCS,
// uptime). Reset on restart like everything else here.
type ProcessStats struct {
	UptimeS       int64  `json:"uptime_s"`
	Goroutines    int    `json:"goroutines"`
	MemAllocBytes uint64 `json:"mem_alloc_bytes"`
	MemSysBytes   uint64 `json:"mem_sys_bytes"`
	GOMAXPROCS    int    `json:"gomaxprocs"`
	StartedAt     string `json:"started_at"`
}

// RequestMetrics is the aggregate + per-route request rollup.
type RequestMetrics struct {
	Total   uint64            `json:"total"`
	ByClass map[string]uint64 `json:"by_class"`
	Routes  []RouteMetric     `json:"routes"`
}

// RouteMetric is one (method, route-template) row.
type RouteMetric struct {
	Route     string            `json:"route"`
	Method    string            `json:"method"`
	Count     uint64            `json:"count"`
	ByClass   map[string]uint64 `json:"by_class"`
	ErrorRate float64           `json:"error_rate"`
	P50Ms     float64           `json:"p50_ms"`
	P95Ms     float64           `json:"p95_ms"`
	P99Ms     float64           `json:"p99_ms"`
	MeanMs    float64           `json:"mean_ms"`
	LastSeen  string            `json:"last_seen"`
}

// snapshot builds the JSON view. It copies each route's state under that
// route's lock so the walk never races with live record() calls, then computes
// derived fields (percentiles, error rate, mean) outside the locks.
func (o *opsRegistry) snapshot() OpsMetricsResponse {
	o.mu.RLock()
	stats := make([]*routeStat, 0, len(o.routes))
	for _, s := range o.routes {
		stats = append(stats, s)
	}
	o.mu.RUnlock()

	routes := make([]RouteMetric, 0, len(stats))
	var total uint64
	overall := map[string]uint64{}
	for _, s := range stats {
		s.mu.Lock()
		count := s.count
		byClass := s.byClass
		sumMs := s.sumMs
		buckets := s.buckets
		lastSeen := s.lastSeen
		method := s.method
		template := s.template
		s.mu.Unlock()

		if count == 0 {
			continue
		}
		rm := RouteMetric{
			Route:   template,
			Method:  method,
			Count:   count,
			ByClass: map[string]uint64{},
			P50Ms:   percentileMs(&buckets, count, 0.50),
			P95Ms:   percentileMs(&buckets, count, 0.95),
			P99Ms:   percentileMs(&buckets, count, 0.99),
			MeanMs:  sumMs / float64(count),
		}
		for class := 1; class <= 5; class++ {
			if n := byClass[class]; n > 0 {
				label := classLabel(class)
				rm.ByClass[label] = n
				overall[label] += n
			}
		}
		rm.ErrorRate = float64(byClass[4]+byClass[5]) / float64(count)
		if lastSeen > 0 {
			rm.LastSeen = time.UnixMilli(lastSeen).UTC().Format(time.RFC3339)
		}
		total += count
		routes = append(routes, rm)
	}

	// Stable output: most-trafficked routes first, ties broken by name.
	sort.Slice(routes, func(i, j int) bool {
		if routes[i].Count != routes[j].Count {
			return routes[i].Count > routes[j].Count
		}
		if routes[i].Method != routes[j].Method {
			return routes[i].Method < routes[j].Method
		}
		return routes[i].Route < routes[j].Route
	})

	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	return OpsMetricsResponse{
		Process: ProcessStats{
			UptimeS:       int64(time.Since(processStart).Seconds()),
			Goroutines:    runtime.NumGoroutine(),
			MemAllocBytes: mem.Alloc,
			MemSysBytes:   mem.Sys,
			GOMAXPROCS:    runtime.GOMAXPROCS(0),
			StartedAt:     processStart.UTC().Format(time.RFC3339),
		},
		Requests: RequestMetrics{
			Total:   total,
			ByClass: overall,
			Routes:  routes,
		},
		Upstream: upstreamCountsSnapshot(),
	}
}

// upstreamCountsSnapshot flattens the existing process-lifetime provider
// counters (places_service.go / events_service.go) and the AI-health tracker
// (ai_health.go) into a flat map for the ops view. Read-only: it never mutates
// the counters, which stay owned by their services and are also surfaced
// (priced) by adminMetricsHandler.
func upstreamCountsSnapshot() map[string]int64 {
	m := map[string]int64{}
	if placesService != nil {
		for name, c := range map[string]*upstreamCallCounters{
			"places_search":       &placesService.searchCalls,
			"places_autocomplete": &placesService.autocompleteCalls,
			"places_details":      &placesService.detailsCalls,
			"places_photo_lookup": &placesService.photoLookupCalls,
			"places_photo":        &placesService.photoCalls,
		} {
			m[name+"_upstream"] = c.upstream.Load()
			m[name+"_cache_hits"] = c.cacheHits.Load()
		}
	}
	if eventsService != nil {
		m["events_upstream"] = eventsService.calls.upstream.Load()
		m["events_cache_hits"] = eventsService.calls.cacheHits.Load()
	}
	ai := aiHealth.state()
	m["ai_success_total"] = ai.SuccessTotal
	m["ai_transient_total"] = ai.TransientTotal
	m["ai_fatal_total"] = ai.FatalTotal
	m["ai_consecutive_fatal"] = ai.ConsecutiveFatal
	return m
}

// metricsMiddleware times each request and folds its (method, route-template,
// status, latency) into opsMetrics. It reuses statusRecorder (middleware.go) so
// the status code is captured and http.Flusher is preserved for SSE. The route
// template — not the concrete path — is the key, so per-id routes like
// /trips/{id} collapse to one row instead of exploding cardinality; an
// unmatched route (no template) is grouped under "other".
func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(rec, r)
		dur := time.Since(start)

		template := "other"
		if route := mux.CurrentRoute(r); route != nil {
			if t, err := route.GetPathTemplate(); err == nil && t != "" {
				template = t
			}
		}
		opsMetrics.record(r.Method, template, rec.status, dur)
	})
}
