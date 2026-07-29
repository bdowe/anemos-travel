package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// swapPlacesService installs a fresh service as the process singleton for one
// test — the handler under test reads the package-level placesService.
func swapPlacesService(t *testing.T, svc *GooglePlacesService) {
	t.Helper()
	prev := placesService
	placesService = svc
	t.Cleanup(func() { placesService = prev })
}

func TestClampPhotoWidth(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"", 400}, {"garbage", 400}, {"0", 400}, {"-5", 400},
		{"150", 200}, {"200", 200}, {"250", 400}, {"400", 400},
		{"401", 800}, {"800", 800}, {"999", 800}, {"99999999999", 800},
	}
	for _, c := range cases {
		if got := clampPhotoWidth(c.in); got != c.want {
			t.Errorf("clampPhotoWidth(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestPhotoHandlerMissingRef400(t *testing.T) {
	rec := httptest.NewRecorder()
	placesPhotoHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/places/photo", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}

	rec = httptest.NewRecorder()
	long := strings.Repeat("x", 1025)
	placesPhotoHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref="+long, nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("oversized ref status = %d, want 400", rec.Code)
	}
}

// The known-ref gate is the billing firewall: a ref this process never handed
// out must 404 with ZERO upstream Google calls — otherwise /places/photo is an
// open proxy billed to us.
func TestPhotoHandlerUnknownRef404NoUpstream(t *testing.T) {
	rt := &redirectTransport{location: "https://lh3.googleusercontent.com/x"}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.PhotoClient.Transport = rt
	swapPlacesService(t, svc)

	rec := httptest.NewRecorder()
	placesPhotoHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=never-issued", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	if rt.calls != 0 {
		t.Fatalf("gate leaked %d upstream calls for an unknown ref", rt.calls)
	}
}

func TestPhotoHandlerKnownRefRedirectsWithCacheControl(t *testing.T) {
	rt := &redirectTransport{location: "https://lh3.googleusercontent.com/img-1"}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.PhotoClient.Transport = rt
	svc.allowPhotoRef("known-ref")
	swapPlacesService(t, svc)

	rec := httptest.NewRecorder()
	placesPhotoHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=known-ref&w=400", nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	if got := rec.Header().Get("Location"); got != "https://lh3.googleusercontent.com/img-1" {
		t.Fatalf("Location = %q", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "public, max-age=21600" {
		t.Fatalf("Cache-Control = %q", got)
	}
	if !strings.Contains(rt.lastURL, "maxwidth=400") {
		t.Fatalf("upstream URL missing width: %s", rt.lastURL)
	}
}

// Widths outside the allowlist must be snapped before reaching Google, so the
// ref|width cache stays at three variants per photo.
func TestPhotoHandlerWidthClamped(t *testing.T) {
	rt := &redirectTransport{location: "https://lh3.googleusercontent.com/img-2"}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.PhotoClient.Transport = rt
	svc.allowPhotoRef("known-ref")
	swapPlacesService(t, svc)

	rec := httptest.NewRecorder()
	placesPhotoHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=known-ref&w=999", nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	if !strings.Contains(rt.lastURL, "maxwidth=800") {
		t.Fatalf("w=999 not clamped to 800: %s", rt.lastURL)
	}
}

// A ref Google itself rejects (expired/invalid) is a 404 to the client — same
// as the gate's 404, so probing can't distinguish the two — never a 500 that
// would page anyone.
func TestPhotoHandlerUpstreamRejectionMaps404(t *testing.T) {
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.PhotoClient.Transport = notFoundTransport{status: http.StatusBadRequest}
	svc.allowPhotoRef("expired-ref")
	swapPlacesService(t, svc)

	rec := httptest.NewRecorder()
	placesPhotoHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=expired-ref", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

// Transport failures / Google 5xx are an upstream outage: 502, generic body.
func TestPhotoHandlerUpstreamOutageMaps502(t *testing.T) {
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key-SECRET"
	svc.PhotoClient.Transport = failingTransport{}
	svc.allowPhotoRef("ok-ref")
	swapPlacesService(t, svc)

	rec := httptest.NewRecorder()
	placesPhotoHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=ok-ref", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", rec.Code)
	}
	if body := rec.Body.String(); strings.Contains(body, "SECRET") || strings.Contains(body, "connection refused") {
		t.Fatalf("502 body leaks upstream detail: %q", body)
	}
}

// The photo endpoint has its own limiter bucket so image fan-out can't starve
// (or be starved by) other traffic. Middleware-level test matching
// TestRateLimitMiddlewareReturns429; the wiring numbers live in main.go.
func TestPhotoRateLimiterIndependentBuckets(t *testing.T) {
	rt := &redirectTransport{location: "https://lh3.googleusercontent.com/img-3"}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.PhotoClient.Transport = rt
	svc.allowPhotoRef("known-ref")
	swapPlacesService(t, svc)

	limiter := newIPRateLimiter(40, 2)
	handler := rateLimitMiddleware(limiter)(http.HandlerFunc(placesPhotoHandler))

	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=known-ref", nil)
		req.RemoteAddr = "203.0.113.9:1000"
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusFound {
			t.Fatalf("request %d within burst: status %d, want 302", i+1, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=known-ref", nil)
	req.RemoteAddr = "203.0.113.9:1000"
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("beyond burst: status %d, want 429", rec.Code)
	}
	// A different IP has its own bucket.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/api/v1/places/photo?ref=known-ref", nil)
	req.RemoteAddr = "198.51.100.7:1000"
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound {
		t.Fatalf("distinct IP throttled: status %d, want 302", rec.Code)
	}
}
