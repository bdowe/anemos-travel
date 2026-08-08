package main

import (
	"net/http"
	"time"
)

// sharedTransport is the one process-wide *http.Transport behind every
// outbound upstream client (Places, weather, events, Duffel, SerpApi,
// transcription, Google/Apple OAuth). Each service previously built its own
// &http.Client{} with a nil Transport, which gave every service a private
// connection pool sized by DefaultTransport's MaxIdleConnsPerHost of 2 — so
// hot upstreams (Google Places under the /plan agent loop) paid a fresh
// TCP+TLS handshake on most calls. One shared transport means one pool of
// warm keep-alive connections across the process.
//
// Cloned from http.DefaultTransport so we inherit its proxy/dialer/TLS
// defaults and only override pool sizing.
var sharedTransport = func() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.MaxIdleConns = 100
	t.MaxIdleConnsPerHost = 16
	t.IdleConnTimeout = 90 * time.Second
	t.ForceAttemptHTTP2 = true
	return t
}()

// newUpstreamClient builds an outbound client on the shared transport with
// the caller's overall-request timeout. Timeouts stay per-service (a Duffel
// offers search legitimately runs 60s; a Places lookup must die at 15s) —
// only the connection pool is shared. Sites that need extra client fields
// (e.g. the Places PhotoClient's CheckRedirect) construct their own
// http.Client and set Transport: sharedTransport directly.
func newUpstreamClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout:   timeout,
		Transport: sharedTransport,
	}
}
