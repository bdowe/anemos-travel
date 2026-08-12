package main

import (
	"context"
	"log"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Free-cap soft instrumentation (specs/free-cap-instrumentation): measure the
// business model's placeholder free caps WITHOUT enforcing anything. When a
// signed-in user crosses a cap — the first unit past it, never subsequent
// ones — a server-side free_cap_would_hit analytics event is recorded so the
// admin dashboard can answer the Phase-3 trigger question ("is a measured
// cohort actually hitting the free caps?"). Everything here is strictly
// fail-open: counting off the best-effort analytics_events log undercounts in
// degraded mode (acceptable for a demand signal — see the spec's accuracy
// model and its usage_counters upgrade path for strict metering), and any
// error simply skips the signal. No request is ever rejected, delayed, or
// altered. Same count-first template as the per-user data-volume caps
// (validation.go), minus the enforcement branch.

const (
	defaultFreePlanSessionsPerMonth = 20 // business-model §4 placeholder
	defaultFreeActiveTrips          = 3  // business-model §4 placeholder

	// freeCapWindowDays is the trailing window for the plan_runs cap —
	// rolling, not calendar-month, to avoid month-boundary cliffs.
	freeCapWindowDays = 30
)

// Read at call time (the envInt pattern) so tests and ops can
// lower a cap via env without a boot-order dependency. Invalid/zero/negative
// values fall back to the default.
func freePlanSessionsPerMonth() int {
	return envInt("FREE_PLAN_SESSIONS_PER_MONTH", defaultFreePlanSessionsPerMonth)
}

func freeActiveTrips() int {
	return envInt("FREE_ACTIVE_TRIPS", defaultFreeActiveTrips)
}

// recordPlanSessionStart is the /plan session-start instrumentation: it
// records the plan_session_started event (for every caller, as before) and,
// for signed-in users, the plan_runs free-cap crossing signal. Run it in a
// goroutine — nothing here may sit on the SSE hot path.
//
// Crossing rule (only-on-crossing): count the user's PRIOR
// plan_session_started events in the trailing 30 days — prior, because this
// session's own started event is written afterwards, so the session being
// started never counts itself. Emit free_cap_would_hit iff prior == cap:
// sessions 1..cap are within the free tier, session cap+1 is the first that
// would have been blocked and the only one that emits (prior > cap emits
// nothing). The would-hit is written BEFORE the started event so that once a
// session's started row is visible, any crossing it implies is visible too
// (what the integration test polls on). Concurrent same-user starts can race
// the threshold either way; accepted — the signal is approximate by design.
func recordPlanSessionStart(userID *uuid.UUID, authed bool) {
	var crossingCount int64
	if userID != nil && dbPool != nil {
		limit := freePlanSessionsPerMonth()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		prior, err := store.New(dbPool).CountEventsByTypeAndUserSince(ctx, store.CountEventsByTypeAndUserSinceParams{
			EventType: "plan_session_started",
			UserID:    pgtype.UUID{Bytes: *userID, Valid: true},
			CreatedAt: time.Now().AddDate(0, 0, -freeCapWindowDays),
		})
		cancel()
		switch {
		case err != nil:
			// Fail open: no crossing signal, session proceeds untouched.
			log.Printf("free cap: plan_runs count failed (skipping signal): %v", err)
		case prior == int64(limit):
			crossingCount = prior + 1
		}
	}
	if crossingCount > 0 {
		recordEventOpt(userID, "free_cap_would_hit", nil, map[string]any{
			"cap_kind": "plan_runs",
			"count":    crossingCount,
		})
	}
	recordEventOpt(userID, "plan_session_started", nil, map[string]any{"authenticated": authed})
}

// recordActiveTripsCapSignal emits the active_trips crossing signal after a
// trip creation has committed (persistTrip via the agent's create_itinerary,
// or duplicating a shared trip).
//
// Crossing rule (only-on-crossing): count the owner's distinct trip lineages
// (COALESCE(chat_id, id) — the My Trips grouping, so new versions of an
// existing lineage never move the count) AFTER the creation, and emit iff the
// count == cap+1 exactly: the creation that took the user from at-the-cap to
// one past it. A user already beyond cap+1 (crossed while degraded, or before
// this shipped) emits nothing — that crossing was missed, not deferred.
// Deleting back under the cap and crossing again emits again (recurring
// pressure is signal). Strictly fail-open; never fails the caller.
func recordActiveTripsCapSignal(userID, tripID uuid.UUID) {
	if dbPool == nil {
		return
	}
	limit := freeActiveTrips()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	n, err := store.New(dbPool).CountActiveTripLineagesByOwner(ctx, userID)
	if err != nil {
		log.Printf("free cap: active_trips count failed (skipping signal): %v", err)
		return
	}
	if n == int64(limit)+1 {
		recordEvent(userID, "free_cap_would_hit", &tripID, map[string]any{
			"cap_kind": "active_trips",
			"count":    n,
		})
	}
}
