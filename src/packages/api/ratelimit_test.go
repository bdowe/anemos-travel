package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestIPRateLimiterAllowsBurstThenBlocks(t *testing.T) {
	l := newIPRateLimiter(60, 3)
	for i := 0; i < 3; i++ {
		if !l.allow("1.2.3.4") {
			t.Fatalf("request %d within burst should be allowed", i+1)
		}
	}
	if l.allow("1.2.3.4") {
		t.Fatal("request beyond burst should be blocked")
	}
	// A different IP has its own bucket.
	if !l.allow("5.6.7.8") {
		t.Fatal("distinct IP should not share the exhausted bucket")
	}
}

func TestClientIPPrefersRightmostForwardedFor(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "172.18.0.5:52000"
	r.Header.Set("X-Forwarded-For", "203.0.113.7, 198.51.100.2")
	if got := clientIP(r); got != "198.51.100.2" {
		t.Fatalf("clientIP = %q, want rightmost XFF entry 198.51.100.2", got)
	}
}

func TestClientIPFallsBackToRemoteAddr(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "192.0.2.9:41234"
	if got := clientIP(r); got != "192.0.2.9" {
		t.Fatalf("clientIP = %q, want RemoteAddr host 192.0.2.9", got)
	}
}

func TestRateLimitMiddlewareReturns429(t *testing.T) {
	l := newIPRateLimiter(60, 1)
	handler := rateLimitMiddleware(l)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	first := httptest.NewRecorder()
	handler.ServeHTTP(first, httptest.NewRequest(http.MethodGet, "/", nil))
	if first.Code != http.StatusOK {
		t.Fatalf("first request status = %d, want 200", first.Code)
	}

	before := rateLimited429s.Load()
	second := httptest.NewRecorder()
	handler.ServeHTTP(second, httptest.NewRequest(http.MethodGet, "/", nil))
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second request status = %d, want 429", second.Code)
	}
	// 60/min refills one token per second — Retry-After must say so, not the
	// old blanket "60".
	if got := second.Header().Get("Retry-After"); got != "1" {
		t.Fatalf("Retry-After = %q, want \"1\"", got)
	}
	if rateLimited429s.Load() != before+1 {
		t.Fatal("a served 429 must increment rateLimited429s")
	}
}

// TestGeneralLimiterAbsorbsColdBootBurst pins the general bucket's sizing to
// the load it exists to absorb (see the generalRate* comment in main.go): two
// back-to-back hard refreshes of a 10-city trip-detail page ≈ 175 requests
// with no meaningful refill in between. If this fails after a resize, the
// boot fan-out no longer fits and real page loads will shed.
func TestGeneralLimiterAbsorbsColdBootBurst(t *testing.T) {
	l := newIPRateLimiter(generalRatePerMinute, generalRateBurst)
	for i := 0; i < 175; i++ {
		if !l.allow("203.0.113.1") {
			t.Fatalf("request %d of a double cold boot should pass (burst %d)",
				i+1, generalRateBurst)
		}
	}
	// The abuse backstop must still exist: a sustained flood past the burst
	// gets shed.
	blocked := false
	for i := 0; i < 30; i++ {
		if !l.allow("203.0.113.1") {
			blocked = true
			break
		}
	}
	if !blocked {
		t.Fatal("sustained flood past the burst must eventually be rate limited")
	}
}

// Retry-After must reflect each bucket's actual refill rate: seconds until
// one token becomes available.
func TestRetryAfterDerivedFromRefillRate(t *testing.T) {
	cases := []struct {
		perMinute float64
		want      string
	}{
		{120, "1"}, // general (2 tokens/s)
		{40, "2"},  // photo tier
		{10, "6"},  // transcribe / anon-events tiers
		{5, "12"},  // strict tier
	}
	for _, c := range cases {
		if got := newIPRateLimiter(c.perMinute, 1).retryAfter; got != c.want {
			t.Fatalf("retryAfter(%v/min) = %q, want %q", c.perMinute, got, c.want)
		}
	}
}
