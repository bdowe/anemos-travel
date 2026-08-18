package main

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
)

// Integration coverage for POST /api/v1/events hardening: trip_id must be
// verified (exists + caller may access it) before it can feed the attach-rate
// numerator, and metadata is constrained to the closed key set the Flutter
// tracker sends. Everything stays best-effort — bad inputs degrade the event,
// never reject it.

// clientEventRow fetches the caller's single booking_link_clicked row.
func clientEventRow(t *testing.T, userID uuid.UUID) (tripID *string, metadata map[string]any) {
	t.Helper()
	var meta map[string]any
	err := dbPool.QueryRow(context.Background(),
		`SELECT trip_id::text, metadata FROM analytics_events
		 WHERE user_id = $1 AND event_type = 'booking_link_clicked'`,
		userID).Scan(&tripID, &meta)
	if err != nil {
		t.Fatalf("clientEventRow: %v", err)
	}
	return tripID, meta
}

func postBookingClick(t *testing.T, token string, tripID *string, metadata map[string]any) {
	t.Helper()
	body := map[string]any{"event_type": "booking_link_clicked", "metadata": metadata}
	if tripID != nil {
		body["trip_id"] = *tripID
	}
	rec := doJSON(t, "POST", "/api/v1/events", token, body)
	if rec.Code != 202 {
		t.Fatalf("POST /events = %d, want 202: %s", rec.Code, rec.Body.String())
	}
}

func TestClientEventForeignTripIDIsNulled(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "trip-owner@example.com")
	stranger, strangerToken := createTestUser(t, "stranger@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	tid := trip.ID.String()
	postBookingClick(t, strangerToken, &tid, map[string]any{"provider": "duffel"})
	waitForEventCount(t, stranger.ID, "booking_link_clicked", 1)

	gotTrip, _ := clientEventRow(t, stranger.ID)
	if gotTrip != nil {
		t.Fatalf("foreign trip_id stored as %v, want NULL", *gotTrip)
	}
}

func TestClientEventFabricatedTripIDIsNulled(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "fabricator@example.com")

	fake := uuid.NewString()
	postBookingClick(t, token, &fake, map[string]any{"provider": "duffel"})
	waitForEventCount(t, user.ID, "booking_link_clicked", 1)

	gotTrip, _ := clientEventRow(t, user.ID)
	if gotTrip != nil {
		t.Fatalf("fabricated trip_id stored as %v, want NULL", *gotTrip)
	}

	// The attach-rate numerator must not have moved.
	var n int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(DISTINCT trip_id) FROM analytics_events
		 WHERE event_type = 'booking_link_clicked' AND trip_id IS NOT NULL`).Scan(&n); err != nil {
		t.Fatalf("attach count: %v", err)
	}
	if n != 0 {
		t.Fatalf("trips_with_booking_click = %d, want 0", n)
	}
}

func TestClientEventOwnTripIDIsKept(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "legit-owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	tid := trip.ID.String()
	postBookingClick(t, token, &tid, map[string]any{"provider": "Duffel", "surface": "flight_card"})
	waitForEventCount(t, owner.ID, "booking_link_clicked", 1)

	gotTrip, meta := clientEventRow(t, owner.ID)
	if gotTrip == nil || *gotTrip != tid {
		t.Fatalf("own trip_id = %v, want %s", gotTrip, tid)
	}
	// provider is lowercased at ingest (the dashboard groups on it verbatim).
	if meta["provider"] != "duffel" {
		t.Fatalf("provider = %v, want %q", meta["provider"], "duffel")
	}
	if meta["surface"] != "flight_card" {
		t.Fatalf("surface = %v, want flight_card", meta["surface"])
	}
}

// itinerary_item_added (specs/add-to-itinerary): accepted as a client event,
// with metadata "source" constrained to the closed value set the dashboard
// groups on — anything else is dropped, never stored.
func TestClientEventItineraryItemAdded(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "adder@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	tid := trip.ID.String()

	rec := doJSON(t, "POST", "/api/v1/events", token, map[string]any{
		"event_type": "itinerary_item_added",
		"trip_id":    tid,
		"metadata":   map[string]any{"source": "local_rec"},
	})
	if rec.Code != 202 {
		t.Fatalf("POST /events = %d, want 202: %s", rec.Code, rec.Body.String())
	}
	waitForEventCount(t, owner.ID, "itinerary_item_added", 1)

	var gotTrip *string
	var meta map[string]any
	if err := dbPool.QueryRow(context.Background(),
		`SELECT trip_id::text, metadata FROM analytics_events
		 WHERE user_id = $1 AND event_type = 'itinerary_item_added'`,
		owner.ID).Scan(&gotTrip, &meta); err != nil {
		t.Fatalf("event row: %v", err)
	}
	if gotTrip == nil || *gotTrip != tid {
		t.Fatalf("trip_id = %v, want %s", gotTrip, tid)
	}
	if meta["source"] != "local_rec" {
		t.Fatalf("source = %v, want local_rec", meta["source"])
	}

	// A free-form source value is dropped (closed set: local_rec/event/guide_pin).
	rec = doJSON(t, "POST", "/api/v1/events", token, map[string]any{
		"event_type": "itinerary_item_added",
		"metadata":   map[string]any{"source": "totally_made_up", "kind": "place"},
	})
	if rec.Code != 202 {
		t.Fatalf("POST /events (bogus source) = %d, want 202", rec.Code)
	}
	waitForEventCount(t, owner.ID, "itinerary_item_added", 2)
	var meta2 map[string]any
	if err := dbPool.QueryRow(context.Background(),
		`SELECT metadata FROM analytics_events
		 WHERE user_id = $1 AND event_type = 'itinerary_item_added' AND trip_id IS NULL`,
		owner.ID).Scan(&meta2); err != nil {
		t.Fatalf("second event row: %v", err)
	}
	if _, ok := meta2["source"]; ok {
		t.Fatalf("bogus source stored: %v", meta2)
	}
	if meta2["kind"] != "place" {
		t.Fatalf("kind = %v, want place", meta2["kind"])
	}
}

// --- anonymous top-of-funnel events (Wave 8) ---

// countAnonymousEvents counts rows with a NULL user_id for one event type.
func countAnonymousEvents(t *testing.T, eventType string) int {
	t.Helper()
	var n int
	err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM analytics_events WHERE user_id IS NULL AND event_type = $1`,
		eventType).Scan(&n)
	if err != nil {
		t.Fatalf("countAnonymousEvents(%s): %v", eventType, err)
	}
	return n
}

// waitForAnonymousEventCount polls for the async insert like waitForEventCount.
func waitForAnonymousEventCount(t *testing.T, eventType string, want int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		n := countAnonymousEvents(t, eventType)
		if n == want {
			return
		}
		if n > want {
			t.Fatalf("anonymous %s count = %d, exceeded expected %d", eventType, n, want)
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %d anonymous %s events (have %d)", want, eventType, n)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestAnonymousEventWhitelistedRecordsNullUser(t *testing.T) {
	resetDB(t)
	rec := doJSON(t, "POST", "/api/v1/events", "", map[string]any{
		"event_type": "landing_viewed",
	})
	if rec.Code != 202 {
		t.Fatalf("anonymous POST /events = %d, want 202: %s", rec.Code, rec.Body.String())
	}
	waitForAnonymousEventCount(t, "landing_viewed", 1)

	var tripID *string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT trip_id::text FROM analytics_events
		 WHERE user_id IS NULL AND event_type = 'landing_viewed'`).Scan(&tripID); err != nil {
		t.Fatalf("row: %v", err)
	}
	if tripID != nil {
		t.Fatalf("trip_id = %v, want NULL", *tripID)
	}
}

func TestAnonymousEventNonWhitelistedRejected(t *testing.T) {
	resetDB(t)
	// A server-side type must not be spoofable anonymously.
	rec := doJSON(t, "POST", "/api/v1/events", "", map[string]any{
		"event_type": "user_registered",
	})
	if rec.Code != 400 {
		t.Fatalf("anonymous POST /events (server type) = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	if n := countAnonymousEvents(t, "user_registered"); n != 0 {
		t.Fatalf("spoofed rows = %d, want 0", n)
	}
}

func TestAnonymousEventTripIDAlwaysNulled(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "anon-trip-owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	// Even a real trip id is dropped: ownership is unverifiable without a
	// user, so anonymous clicks must never feed the attach-rate numerator.
	rec := doJSON(t, "POST", "/api/v1/events", "", map[string]any{
		"event_type": "booking_link_clicked",
		"trip_id":    trip.ID.String(),
		"metadata":   map[string]any{"provider": "Duffel", "evil_key": "nope"},
	})
	if rec.Code != 202 {
		t.Fatalf("anonymous POST /events = %d, want 202: %s", rec.Code, rec.Body.String())
	}
	waitForAnonymousEventCount(t, "booking_link_clicked", 1)

	var tripID *string
	var meta map[string]any
	if err := dbPool.QueryRow(context.Background(),
		`SELECT trip_id::text, metadata FROM analytics_events
		 WHERE user_id IS NULL AND event_type = 'booking_link_clicked'`).Scan(&tripID, &meta); err != nil {
		t.Fatalf("row: %v", err)
	}
	if tripID != nil {
		t.Fatalf("trip_id = %v, want NULL", *tripID)
	}
	// The #71 metadata whitelist applies to anonymous events too.
	if meta["provider"] != "duffel" || len(meta) != 1 {
		t.Fatalf("metadata = %v, want exactly {provider: duffel}", meta)
	}

	// And the attach-rate numerator must not have moved.
	var n int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(DISTINCT trip_id) FROM analytics_events
		 WHERE event_type = 'booking_link_clicked' AND trip_id IS NOT NULL`).Scan(&n); err != nil {
		t.Fatalf("attach count: %v", err)
	}
	if n != 0 {
		t.Fatalf("trips_with_booking_click = %d, want 0", n)
	}
}

func TestEventsInvalidTokenIs401NotAnonymous(t *testing.T) {
	resetDB(t)
	// A presented-but-invalid token must be rejected by the authed route,
	// never silently downgraded to an anonymous write.
	rec := doJSON(t, "POST", "/api/v1/events", "not-a-real-session", map[string]any{
		"event_type": "landing_viewed",
	})
	if rec.Code != 401 {
		t.Fatalf("POST /events with bad token = %d, want 401: %s", rec.Code, rec.Body.String())
	}
	if n := countAnonymousEvents(t, "landing_viewed"); n != 0 {
		t.Fatalf("anonymous rows after 401 = %d, want 0", n)
	}
}

func TestAnonymousEventsAreStrictRateLimited(t *testing.T) {
	resetDB(t)
	ip := nextTestIP()
	limited := false
	// Anonymous /events has its own bucket (burst 5 at 10/min — separate from
	// the strict tier so pre-signup pings can't 429 /auth/register): within a
	// burst from one IP, a 429 must appear well before 20 requests.
	for i := 0; i < 20; i++ {
		rec := doJSONFromIP(t, "POST", "/api/v1/events", "", ip, map[string]any{
			"event_type": "landing_viewed",
		})
		if rec.Code == 429 {
			limited = true
			break
		}
		if rec.Code != 202 {
			t.Fatalf("request %d = %d, want 202 or 429: %s", i+1, rec.Code, rec.Body.String())
		}
	}
	if !limited {
		t.Fatalf("anonymous /events never rate limited within a 20-request burst")
	}
}

// TestAnonymousEventsDoNotDrainAuthBudget pins the review fix: a visitor's
// pre-signup analytics pings must not consume the strict bucket that
// /auth/register depends on at the conversion moment.
func TestAnonymousEventsDoNotDrainAuthBudget(t *testing.T) {
	resetDB(t)
	ip := nextTestIP()
	for i := 0; i < 3; i++ {
		rec := doJSONFromIP(t, "POST", "/api/v1/events", "", ip, map[string]any{
			"event_type": "booking_link_clicked",
		})
		if rec.Code != 202 {
			t.Fatalf("event %d = %d, want 202", i+1, rec.Code)
		}
	}
	rec := doJSONFromIP(t, "POST", "/api/v1/auth/register", "", ip, map[string]any{
		"email":    "converts@example.com",
		"password": "a-strong-password-1",
		"name":     "Converting Visitor",
	})
	if rec.Code == 429 {
		t.Fatalf("register 429 after anonymous analytics pings — events drained the auth budget")
	}
}

func TestAuthedEventsNotOnStrictTier(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "authed-clicker@example.com")
	ip := nextTestIP()
	// Authed clicks stay on the general limiter only (burst 30): a burst of
	// 10 from one IP — over the strict tier's burst — must all be accepted.
	for i := 0; i < 10; i++ {
		rec := doJSONFromIP(t, "POST", "/api/v1/events", token, ip, map[string]any{
			"event_type": "booking_link_clicked",
			"metadata":   map[string]any{"provider": "duffel"},
		})
		if rec.Code != 202 {
			t.Fatalf("authed request %d = %d, want 202: %s", i+1, rec.Code, rec.Body.String())
		}
	}
	waitForEventCount(t, user.ID, "booking_link_clicked", 10)
}

func TestClientEventMetadataSanitized(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "meta-abuser@example.com")

	long := make([]byte, maxClientMetadataValueLen+1)
	for i := range long {
		long[i] = 'x'
	}
	postBookingClick(t, token, nil, map[string]any{
		"provider": "FerryHopper",
		"surface":  string(long),     // oversized value: dropped
		"kind":     42,               // non-string value: dropped
		"evil_key": "not-in-the-set", // unknown key: dropped
		"todo_key": "flight_JFK_CDG", // allowed, kept
		"cap_kind": "active_trips",   // unknown key (server-event field): dropped
	})
	waitForEventCount(t, user.ID, "booking_link_clicked", 1)

	_, meta := clientEventRow(t, user.ID)
	want := map[string]any{"provider": "ferryhopper", "todo_key": "flight_JFK_CDG"}
	if len(meta) != len(want) {
		t.Fatalf("metadata = %v, want exactly %v", meta, want)
	}
	for k, v := range want {
		if meta[k] != v {
			t.Fatalf("metadata[%s] = %v, want %v", k, meta[k], v)
		}
	}
}

// --- landing prompt handoff events (specs/landing-prompt-handoff) ---

func TestAnonymousLandingPromptSubmittedAccepted(t *testing.T) {
	resetDB(t)
	// The submitter is by definition signed out; surface/kind ride the
	// existing metadata whitelist and the prompt TEXT never rides at all.
	rec := doJSON(t, "POST", "/api/v1/events", "", map[string]any{
		"event_type": "landing_prompt_submitted",
		"metadata":   map[string]any{"surface": "card", "kind": "rome"},
	})
	if rec.Code != 202 {
		t.Fatalf("anonymous POST /events = %d, want 202: %s", rec.Code, rec.Body.String())
	}
	waitForAnonymousEventCount(t, "landing_prompt_submitted", 1)

	var meta map[string]any
	if err := dbPool.QueryRow(context.Background(),
		`SELECT metadata FROM analytics_events
		 WHERE user_id IS NULL AND event_type = 'landing_prompt_submitted'`).Scan(&meta); err != nil {
		t.Fatalf("row: %v", err)
	}
	if meta["surface"] != "card" || meta["kind"] != "rome" || len(meta) != 2 {
		t.Fatalf("metadata = %v, want {surface: card, kind: rome}", meta)
	}
}

func TestPendingPromptConsumedAuthedOnly(t *testing.T) {
	resetDB(t)
	// Consuming requires a session — the anonymous whitelist must reject it.
	rec := doJSON(t, "POST", "/api/v1/events", "", map[string]any{
		"event_type": "pending_prompt_consumed",
		"metadata":   map[string]any{"surface": "hero"},
	})
	if rec.Code != 400 {
		t.Fatalf("anonymous POST /events = %d, want 400: %s", rec.Code, rec.Body.String())
	}

	// The authed path accepts it.
	user, token := createTestUser(t, "prompt-consumer@example.com")
	rec = doJSON(t, "POST", "/api/v1/events", token, map[string]any{
		"event_type": "pending_prompt_consumed",
		"metadata":   map[string]any{"surface": "hero"},
	})
	if rec.Code != 202 {
		t.Fatalf("authed POST /events = %d, want 202: %s", rec.Code, rec.Body.String())
	}
	waitForEventCount(t, user.ID, "pending_prompt_consumed", 1)
}
