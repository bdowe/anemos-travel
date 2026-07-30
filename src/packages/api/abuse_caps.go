package main

import (
	"net/http"
	"sync"
	"time"
)

// Abuse & cost caps (Hardening PR2). These guard a single-instance API taking
// real users on a home Raspberry Pi against credential stuffing, runaway
// anonymous AI spend, email-bombing, mass signups, and being swamped.
//
// Like ipRateLimiter (ratelimit.go), all state here is deliberately in-memory:
// the API runs as one instance behind the nginx gateway, so process-local
// counters are correct and reset-on-restart is acceptable (a restart is a rare,
// operator-driven event that also clears any in-progress attack). A
// multi-instance deployment would move this behind a shared store (e.g. Redis)
// at the same seams. Every map evicts idle keys via a janitor so churn can't
// grow it unbounded, mirroring ipRateLimiter's structure.

// --- tunables (env-overridable via envInt; read at call time like the ALERT_*
// and FREE_* knobs so ops/tests can adjust without a boot-order dependency) ---

const (
	// Login lockout: consecutive failed logins to one email before a temporary
	// lock, and how long that lock lasts.
	defaultLoginMaxFailures = 5
	defaultLoginLockMinutes = 15

	// Anonymous /plan requests allowed per client IP per UTC day. The key money
	// fix: authenticated callers are exempt (see anonPlanAllowed).
	defaultAnonPlanPerDay = 5

	// New accounts allowed per client IP per UTC day.
	defaultRegistrationsPerIPPerDay = 10

	// Trip imports allowed per user per UTC day. Each import is one Sonnet
	// extraction call plus up to importMaxPlaceLookups paid Places lookups, and
	// the per-IP strict tier alone doesn't bound a single account driving many
	// IPs — this is the per-account spend ceiling.
	defaultImportsPerDay = 10

	// Minimum seconds between transactional emails (verify / reset) to the same
	// address, per purpose.
	defaultEmailMinIntervalSeconds = 60

	// Max simultaneously in-flight HTTP requests across the whole server.
	defaultMaxInflightRequests = 100
)

func loginMaxFailures() int { return envInt("LOGIN_MAX_FAILURES", defaultLoginMaxFailures) }
func loginLockWindow() time.Duration {
	return time.Duration(envInt("LOGIN_LOCK_MINUTES", defaultLoginLockMinutes)) * time.Minute
}
func anonPlanPerDay() int { return envInt("FREE_ANON_PLAN_PER_DAY", defaultAnonPlanPerDay) }
func importsPerDay() int  { return envInt("FREE_IMPORTS_PER_DAY", defaultImportsPerDay) }
func registrationsPerIPPerDay() int {
	return envInt("MAX_REGISTRATIONS_PER_IP_PER_DAY", defaultRegistrationsPerIPPerDay)
}
func emailMinInterval() time.Duration {
	return time.Duration(envInt("EMAIL_MIN_INTERVAL_SECONDS", defaultEmailMinIntervalSeconds)) * time.Second
}
func maxInflightRequests() int { return envInt("MAX_INFLIGHT_REQUESTS", defaultMaxInflightRequests) }

// utcDay is the integer UTC day number (days since the Unix epoch). It rolls
// over exactly at UTC midnight, giving daily counters a cheap, monotone bucket
// key without storing calendar dates.
func utcDay(now time.Time) int64 { return now.UTC().Unix() / 86400 }

// --- process-wide singletons ---
//
// Constructed at package init (each spawns its janitor goroutine, same as
// newIPRateLimiter). Tests reset them in place via resetAll rather than
// reconstructing, to avoid leaking janitors.
var (
	loginLockouts       = newLockoutTracker(loginMaxFailures, loginLockWindow)
	anonPlanCounter     = newDailyCounter()
	registrationCounter = newDailyCounter()
	importCounter       = newDailyCounter()
	emailSendThrottle   = newIntervalThrottle()
)

// =============================================================================
// Login lockout — per-email consecutive-failure tracker with a timed lock.
// =============================================================================

type lockoutEntry struct {
	failures    int
	lockedUntil time.Time
	lastSeen    time.Time
}

type lockoutTracker struct {
	mu      sync.Mutex
	entries map[string]*lockoutEntry
	maxFail func() int
	window  func() time.Duration
}

func newLockoutTracker(maxFail func() int, window func() time.Duration) *lockoutTracker {
	l := &lockoutTracker{
		entries: make(map[string]*lockoutEntry),
		maxFail: maxFail,
		window:  window,
	}
	go l.janitor()
	return l
}

// locked reports whether key is currently within an active lock window.
func (l *lockoutTracker) locked(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.entries[key]
	return e != nil && now.Before(e.lockedUntil)
}

// recordFailure counts one failed attempt for key and, on reaching the
// threshold, locks it for the window. An expired prior lock resets the counter
// so a returning-but-fresh attacker starts over. Returns whether key is now
// locked.
func (l *lockoutTracker) recordFailure(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.entries[key]
	if e == nil {
		e = &lockoutEntry{}
		l.entries[key] = e
	}
	e.lastSeen = now
	if !e.lockedUntil.IsZero() && !now.Before(e.lockedUntil) {
		// The last lock has elapsed; start a fresh failure streak.
		e.failures = 0
		e.lockedUntil = time.Time{}
	}
	e.failures++
	if e.failures >= l.maxFail() {
		e.lockedUntil = now.Add(l.window())
		return true
	}
	return false
}

// reset clears all failure state for key (a successful login).
func (l *lockoutTracker) reset(key string) {
	l.mu.Lock()
	delete(l.entries, key)
	l.mu.Unlock()
}

func (l *lockoutTracker) resetAll() {
	l.mu.Lock()
	l.entries = make(map[string]*lockoutEntry)
	l.mu.Unlock()
}

func (l *lockoutTracker) janitor() {
	for range time.Tick(5 * time.Minute) {
		// Evict entries idle beyond the lock window plus a margin: once a lock
		// has long expired and nothing has touched the key, it can't affect any
		// decision, so it's safe to drop.
		cutoff := time.Now().Add(-l.window() - 10*time.Minute)
		l.mu.Lock()
		for k, e := range l.entries {
			if e.lastSeen.Before(cutoff) {
				delete(l.entries, k)
			}
		}
		l.mu.Unlock()
	}
}

// =============================================================================
// Daily counter — per-key count within the current UTC day, rolling at
// midnight. Shared by the anonymous /plan cap and the registration ceiling.
// =============================================================================

type dailyEntry struct {
	day      int64
	count    int
	lastSeen time.Time
}

type dailyCounter struct {
	mu      sync.Mutex
	entries map[string]*dailyEntry
}

func newDailyCounter() *dailyCounter {
	c := &dailyCounter{entries: make(map[string]*dailyEntry)}
	go c.janitor()
	return c
}

// incr bumps key's counter for now's UTC day (resetting first if the stored
// day is stale) and returns the post-increment count for today.
func (c *dailyCounter) incr(key string, now time.Time) int {
	day := utcDay(now)
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.entries[key]
	if e == nil || e.day != day {
		e = &dailyEntry{day: day}
		c.entries[key] = e
	}
	e.count++
	e.lastSeen = now
	return e.count
}

// count returns key's count for now's UTC day without incrementing (a stale
// day reads as zero).
func (c *dailyCounter) count(key string, now time.Time) int {
	day := utcDay(now)
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.entries[key]
	if e == nil || e.day != day {
		return 0
	}
	return e.count
}

func (c *dailyCounter) resetAll() {
	c.mu.Lock()
	c.entries = make(map[string]*dailyEntry)
	c.mu.Unlock()
}

func (c *dailyCounter) janitor() {
	for range time.Tick(1 * time.Hour) {
		cutoff := time.Now().Add(-26 * time.Hour) // one full day + margin
		c.mu.Lock()
		for k, e := range c.entries {
			if e.lastSeen.Before(cutoff) {
				delete(c.entries, k)
			}
		}
		c.mu.Unlock()
	}
}

// =============================================================================
// Interval throttle — enforces a minimum gap between events for a key. Used to
// rate-limit transactional email sends per address (anti email-bombing).
// =============================================================================

type intervalThrottle struct {
	mu   sync.Mutex
	last map[string]time.Time
}

func newIntervalThrottle() *intervalThrottle {
	t := &intervalThrottle{last: make(map[string]time.Time)}
	go t.janitor()
	return t
}

// allow reports whether at least minInterval has elapsed since the last allowed
// event for key. When it returns true it records now as the new last-allowed
// time; when false it changes nothing.
func (t *intervalThrottle) allow(key string, now time.Time, minInterval time.Duration) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if last, ok := t.last[key]; ok && now.Sub(last) < minInterval {
		return false
	}
	t.last[key] = now
	return true
}

func (t *intervalThrottle) resetAll() {
	t.mu.Lock()
	t.last = make(map[string]time.Time)
	t.mu.Unlock()
}

func (t *intervalThrottle) janitor() {
	for range time.Tick(10 * time.Minute) {
		cutoff := time.Now().Add(-1 * time.Hour)
		t.mu.Lock()
		for k, ts := range t.last {
			if ts.Before(cutoff) {
				delete(t.last, k)
			}
		}
		t.mu.Unlock()
	}
}

// =============================================================================
// Anonymous /plan cap decision.
// =============================================================================

// anonPlanAllowed reports whether a /plan request may proceed under the
// anonymous per-IP daily cap. Authenticated callers (authed=true) always pass
// AND are never counted — the cap is a cost guard against unauthenticated abuse
// only, leaving the measure-only free-cap behavior (free_cap.go) for signed-in
// users exactly as-is. For anonymous callers it increments the per-IP UTC-day
// counter and allows up to anonPlanPerDay() per day; requests beyond that are
// rejected (over-by-one and far-over are not distinguished).
func anonPlanAllowed(authed bool, ip string, now time.Time) bool {
	if authed {
		return true
	}
	return anonPlanCounter.incr(ip, now) <= anonPlanPerDay()
}

// importAllowed reports whether a /trips/import request may proceed under the
// per-user daily cap (specs/import-trip-from-ai-chat). Import is always
// authenticated, so the key is the user id — unlike the per-IP strict tier,
// this bounds one account's upstream spend no matter how many IPs it uses.
func importAllowed(userID string, now time.Time) bool {
	return importCounter.incr(userID, now) <= importsPerDay()
}

// =============================================================================
// Global concurrency limiter — a buffered-channel semaphore capping the number
// of simultaneously in-flight requests. Non-blocking acquire: a full server
// sheds new load with 503 + Retry-After rather than queueing unboundedly (the
// server runs with WriteTimeout:0 for SSE, so there is no other backstop).
// =============================================================================

type concurrencyLimiter struct {
	sem chan struct{}
}

func newConcurrencyLimiter(max int) *concurrencyLimiter {
	if max < 1 {
		max = 1
	}
	return &concurrencyLimiter{sem: make(chan struct{}, max)}
}

func (cl *concurrencyLimiter) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Health probes are never shed: a saturated server still must be able to
		// report its liveness/readiness to the container/orchestrator.
		if r.URL.Path == "/health" || r.URL.Path == "/api/v1/health" {
			next.ServeHTTP(w, r)
			return
		}
		select {
		case cl.sem <- struct{}{}:
			defer func() { <-cl.sem }()
			next.ServeHTTP(w, r)
		default:
			w.Header().Set("Retry-After", "5")
			writeJSONError(w, http.StatusServiceUnavailable, "server busy; please retry shortly")
		}
	})
}
