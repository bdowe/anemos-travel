package main

import (
	"log"
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/time/rate"
)

// Per-IP token-bucket rate limiting. In-memory is deliberate: the API runs as
// a single instance behind the nginx gateway. A multi-instance deployment
// needs a shared store (e.g. Redis) behind the same middleware seam.

type ipLimiterEntry struct {
	limiter  *rate.Limiter
	lastSeen time.Time
}

type ipRateLimiter struct {
	mu      sync.Mutex
	entries map[string]*ipLimiterEntry
	rate    rate.Limit
	burst   int
	// Seconds until one token refills at this bucket's rate — the honest
	// Retry-After for a 429. A blanket "60" taught clients to give up on
	// buckets that refill in a second.
	retryAfter string
}

func newIPRateLimiter(perMinute float64, burst int) *ipRateLimiter {
	l := &ipRateLimiter{
		entries:    make(map[string]*ipLimiterEntry),
		rate:       rate.Limit(perMinute / 60.0),
		burst:      burst,
		retryAfter: strconv.Itoa(int(math.Max(1, math.Ceil(60.0/perMinute)))),
	}
	go l.janitor()
	return l
}

// rateLimited429s counts every 429 served across all buckets. It is the only
// unambiguous "the limiter fired" signal in /admin/ops/metrics
// (rate_limited_total): the per-route request counts fold 429 into a generic
// 4xx class alongside 401/404.
var rateLimited429s atomic.Int64

func (l *ipRateLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	e, ok := l.entries[ip]
	if !ok {
		e = &ipLimiterEntry{limiter: rate.NewLimiter(l.rate, l.burst)}
		l.entries[ip] = e
	}
	e.lastSeen = time.Now()
	return e.limiter.Allow()
}

// janitor evicts limiters idle for 10+ minutes so the map cannot grow
// unbounded under address churn.
func (l *ipRateLimiter) janitor() {
	for range time.Tick(5 * time.Minute) {
		cutoff := time.Now().Add(-10 * time.Minute)
		l.mu.Lock()
		for ip, e := range l.entries {
			if e.lastSeen.Before(cutoff) {
				delete(l.entries, ip)
			}
		}
		l.mu.Unlock()
	}
}

// clientIP resolves the caller's address. The nginx gateway appends the real
// client to X-Forwarded-For ($proxy_add_x_forwarded_for), so the rightmost
// entry is the peer nginx actually saw and cannot be spoofed by the client;
// earlier entries can. Requests that bypass the gateway (local dev on :8080)
// have no X-Forwarded-For and fall back to RemoteAddr.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		if ip := strings.TrimSpace(parts[len(parts)-1]); ip != "" {
			return ip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// rateLimitMiddleware rejects over-limit requests with 429 + Retry-After.
func rateLimitMiddleware(l *ipRateLimiter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !l.allow(clientIP(r)) {
				rateLimited429s.Add(1)
				log.Printf("rate limited %s %s from %s", r.Method, r.URL.Path, clientIP(r))
				w.Header().Set("Retry-After", l.retryAfter)
				writeJSONError(w, http.StatusTooManyRequests, "rate limited; retry shortly")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
