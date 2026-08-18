package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// First-party analytics (specs/instrumentation-events): a lightweight event
// log for the growth-phase funnel numbers — activation, retention, booking
// attach rate, AI cost per user. Recording is strictly best-effort: with the
// database down every instrumented flow behaves exactly as before and events
// are silently dropped. No PII beyond the user id.

// clientEventTypes are the only types authenticated POST /events accepts —
// server-side types cannot be spoofed through the client endpoint.
var clientEventTypes = map[string]bool{
	"booking_link_clicked": true,
	// A place added to a trip from a browse surface (local rec, event, guide
	// pin) — specs/add-to-itinerary. Distinguished by metadata "source".
	"itinerary_item_added": true,
	// A landing prompt handed to sign-up, and the moment the stored prompt
	// reached the signed-in composer (specs/landing-prompt-handoff).
	// Distinguished by metadata "surface": hero|card; "kind" carries the
	// destination slug for cards. The prompt text itself never rides.
	"landing_prompt_submitted": true,
	"pending_prompt_consumed":  true,
	// Transition telemetry (specs/server-leg-dates): the client compared the
	// server `legs` payload against its local derivation on a trip load and
	// they DISAGREED. Expected volume: zero — any row is a derivation-parity
	// bug and blocks the stage-2a client repoint. Remove at stage 6a.
	"legs_parity_mismatch": true,
}

// anonymousClientEventTypes is the tighter whitelist for UNAUTHENTICATED
// POST /events — the pre-signup top of the funnel. Deliberately tiny: this is
// a spam-writable surface (no identity, only the strict per-IP limiter
// bounding it), so only the moments a signed-out visitor can actually produce
// are accepted:
//   - landing_viewed        — the marketing landing page rendered (once per
//     app session, guarded client-side).
//   - booking_link_clicked  — a signed-out booking handoff (the attach-rate
//     event; anonymous rows never carry a trip_id, see below).
//
// There is intentionally no plan_started_anonymous: the Flutter app has no
// signed-out planning entry point, and anonymous direct /plan calls are
// already recorded server-side as plan_session_started with a NULL user_id
// (the plan_sessions_anonymous metric).
var anonymousClientEventTypes = map[string]bool{
	"landing_viewed":       true,
	"booking_link_clicked": true,
	// The landing hero's prompt submit — by definition produced signed out
	// (specs/landing-prompt-handoff). Its consume-side sibling
	// (pending_prompt_consumed) is deliberately NOT here: consuming requires
	// a session.
	"landing_prompt_submitted": true,
}

// maxEventMetadataBytes caps the metadata bag (small, flat detail only).
const maxEventMetadataBytes = 2048

// clientEventMetadataKeys is the closed set of metadata keys POST /events
// accepts — exactly what lib/utils/tracked_launch.dart sends. Metadata feeds
// GROUP BYs on the admin dashboard (BookingClicksByProvider), so arbitrary
// client-chosen keys/values must not reach storage.
var clientEventMetadataKeys = map[string]bool{
	"provider": true,
	"surface":  true,
	"kind":     true,
	"todo_key": true,
	"source":   true,
}

// clientEventSourceValues is the closed value set for the "source" metadata
// key (itinerary_item_added) — it feeds dashboard GROUP BYs, so free-form
// client values are dropped, not stored.
var clientEventSourceValues = map[string]bool{
	"local_rec":  true,
	"event":      true,
	"guide_pin":  true,
	"chat_place": true,
}

// maxClientMetadataValueLen caps each accepted metadata value; real values
// are short slugs ("duffel", "booking_checklist").
const maxClientMetadataValueLen = 64

// sanitizeClientEventMetadata keeps only whitelisted keys whose values are
// non-empty strings within the length cap; everything else is dropped
// (best-effort tracking, never an error). provider is lowercased because the
// dashboard groups on it verbatim.
func sanitizeClientEventMetadata(in map[string]any) map[string]any {
	var out map[string]any
	for k, v := range in {
		if !clientEventMetadataKeys[k] {
			continue
		}
		s, ok := v.(string)
		if !ok || s == "" || len(s) > maxClientMetadataValueLen {
			continue
		}
		if k == "provider" {
			s = strings.ToLower(s)
		}
		if k == "source" && !clientEventSourceValues[s] {
			continue
		}
		if out == nil {
			out = map[string]any{}
		}
		out[k] = s
	}
	return out
}

// recordEvent writes one analytics event. Fire-and-forget semantics: errors
// are logged, never returned — callers must not branch on instrumentation.
func recordEvent(userID uuid.UUID, eventType string, tripID *uuid.UUID, metadata map[string]any) {
	recordEventOpt(&userID, eventType, tripID, metadata)
}

// recordEventOpt is recordEvent for flows where the caller may be anonymous
// (nil userID), e.g. the public /plan endpoint. Uses its own timeout off
// context.Background() so recording survives handler teardown (several call
// sites are goroutines or post-stream code).
func recordEventOpt(userID *uuid.UUID, eventType string, tripID *uuid.UUID, metadata map[string]any) {
	if dbPool == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var meta []byte
	if len(metadata) > 0 {
		b, err := json.Marshal(metadata)
		if err != nil || len(b) > maxEventMetadataBytes {
			log.Printf("analytics: dropping oversized/unencodable metadata for %s", eventType)
		} else {
			meta = b
		}
	}
	var tid pgtype.UUID
	if tripID != nil {
		tid = pgtype.UUID{Bytes: *tripID, Valid: true}
	}
	var uidParam pgtype.UUID
	if userID != nil {
		uidParam = pgtype.UUID{Bytes: *userID, Valid: true}
	}
	if err := store.New(dbPool).CreateAnalyticsEvent(ctx, store.CreateAnalyticsEventParams{
		UserID:    uidParam,
		EventType: eventType,
		TripID:    tid,
		Metadata:  meta,
	}); err != nil {
		log.Printf("analytics: could not record %s: %v", eventType, err)
	}
}

// clientEventRequest is the POST /api/v1/events payload, shared by the
// authenticated and anonymous handlers.
type clientEventRequest struct {
	EventType string         `json:"event_type"`
	TripID    *string        `json:"trip_id"`
	Metadata  map[string]any `json:"metadata"`
}

// recordClientEventHandler is authenticated POST /api/v1/events — client
// funnel moments from signed-in users. Always 202 once the payload is valid,
// even when persistence is degraded: tracking must never surface as a user
// error.
func recordClientEventHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	var req clientEventRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if !clientEventTypes[req.EventType] {
		writeJSONError(w, http.StatusBadRequest, "event_type is missing or not permitted")
		return
	}
	var tripID *uuid.UUID
	if req.TripID != nil {
		if tid, err := uuid.Parse(*req.TripID); err == nil {
			tripID = &tid
		}
	}
	meta := sanitizeClientEventMetadata(req.Metadata)
	safeGo("recordClientEvent", func() {
		// Best-effort trip validation off the response path: attach-rate
		// counts DISTINCT trip_id, so a fabricated/foreign UUID must not be
		// stored. A trip_id survives only when the trip exists and the caller
		// may access it (owner or editor collaborator — the same
		// GetEditableTripByID gate the trip endpoints use); any mismatch or
		// lookup error nulls the reference instead of rejecting the event.
		// Skipped in degraded mode (recordEvent drops the event then anyway).
		if tripID != nil && dbPool != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			// Viewable (not editable): viewer follows may attribute client
			// events (e.g. booking link clicks) to the trip they can read.
			if _, err := store.New(dbPool).GetViewableTripByID(ctx, store.GetViewableTripByIDParams{
				ID: *tripID, UserID: user.ID,
			}); err != nil {
				tripID = nil
			}
			cancel()
		}
		recordEvent(user.ID, req.EventType, tripID, meta)
	})
	w.WriteHeader(http.StatusAccepted)
}

// recordAnonymousClientEventHandler is unauthenticated POST /api/v1/events —
// the pre-signup top of the funnel. Route registration (main.go) sends only
// requests WITHOUT an Authorization header here, behind the strict per-IP
// limiter; anything presenting a token goes through authMiddleware instead
// (validated and attributed, or 401 — never silently downgraded to
// anonymous).
//
// Spam bounding, since there is no identity to hold accountable:
//   - event_type must be on anonymousClientEventTypes (400 otherwise);
//   - trip_id is ALWAYS dropped — ownership cannot be verified without a
//     user, and the attach-rate numerator counts DISTINCT trip_id, so a
//     fabricated reference must never be stored;
//   - metadata passes the same closed key/value whitelist as authed events;
//   - the strict rate limiter caps write volume per IP.
func recordAnonymousClientEventHandler(w http.ResponseWriter, r *http.Request) {
	var req clientEventRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if !anonymousClientEventTypes[req.EventType] {
		writeJSONError(w, http.StatusBadRequest, "event_type is missing or not permitted for anonymous requests")
		return
	}
	meta := sanitizeClientEventMetadata(req.Metadata)
	safeGo("recordEventOpt", func() { recordEventOpt(nil, req.EventType, nil, meta) })
	w.WriteHeader(http.StatusAccepted)
}

// Claude pricing used for the dashboard's COGS estimates (USD per million
// tokens), pinned to the model plan_handler.go actually calls. If the /plan
// model changes, update this block in the same commit. The resulting est_*
// fields cover Claude spend ONLY — Google Places spend is estimated
// separately from the process-lifetime counters below (a different, non-
// window-scoped basis, so the two estimates are never summed).
const (
	planCostModelID              = "claude-sonnet-4-6"
	planCostInputUSDPerMTok      = 3.00
	planCostOutputUSDPerMTok     = 15.00
	planCostCacheWriteUSDPerMTok = 3.75 // 5-minute-TTL cache write (1.25x input)
	planCostCacheReadUSDPerMTok  = 0.30 // cache read (0.1x input)
)

// estClaudeCostUSD estimates /plan Claude spend from a token breakdown, using
// the planCost* rates above. input_tokens is the uncached remainder — cache
// reads and writes are billed separately at their own rates. Shared by the
// window metrics (MetricsResponse.EstClaudeCostUSD) and the per-user activity
// rows so the two never drift.
func estClaudeCostUSD(inTok, outTok, cacheWriteTok, cacheReadTok int64) float64 {
	return (float64(inTok)*planCostInputUSDPerMTok +
		float64(outTok)*planCostOutputUSDPerMTok +
		float64(cacheWriteTok)*planCostCacheWriteUSDPerMTok +
		float64(cacheReadTok)*planCostCacheReadUSDPerMTok) / 1e6
}

// Google Places pricing used for est_places_cost_usd, in USD per call.
// Source: Google Maps Platform pricing table
// (https://developers.google.com/maps/billing-and-pricing/pricing), list
// prices for the legacy Places API endpoints places_service.go calls:
//   - Text Search:            $32 / 1000 requests
//   - Autocomplete (per-req): $2.83 / 1000 requests (no session tokens used)
//   - Place Details:          $17 / 1000 requests (contact+atmosphere fields)
//   - Photo lookup:           $17 / 1000 requests (details base; fields=photo
//     is Basic Data, $0 on top)
//   - Place Photo:            $7 / 1000 requests
//
// ESTIMATES ONLY: actual billing varies with field masks, session tokens,
// volume tiers, and the monthly free credit. Update alongside any endpoint
// or field-mask change in places_service.go.
const (
	placesCostSearchUSDPerCall       = 32.0 / 1000
	placesCostAutocompleteUSDPerCall = 2.83 / 1000
	placesCostDetailsUSDPerCall      = 17.0 / 1000
	placesCostPhotoLookupUSDPerCall  = 17.0 / 1000
	placesCostPhotoUSDPerCall        = 7.0 / 1000
)

// PlacesCallsSnapshot is the places_calls_since_process_start object: per-
// endpoint-class upstream calls vs cache hits, plus the estimated upstream
// spend those calls represent. PROCESS-LIFETIME (reset on restart/deploy) —
// deliberately NOT scoped to the days window like the rest of
// MetricsResponse, hence the loud field name.
type PlacesCallsSnapshot struct {
	Search       UpstreamCallCounts `json:"search"`
	Autocomplete UpstreamCallCounts `json:"autocomplete"`
	Details      UpstreamCallCounts `json:"details"`
	PhotoLookup  UpstreamCallCounts `json:"photo_lookup"`
	Photo        UpstreamCallCounts `json:"photo"`
	// EstPlacesCostUSD prices the upstream counts with the placesCost*
	// constants above. An estimate of list price, not a bill.
	EstPlacesCostUSD float64 `json:"est_places_cost_usd"`
}

// placesCallsSnapshot prices a point-in-time read of the placesService
// counters.
func placesCallsSnapshot(gps *GooglePlacesService) PlacesCallsSnapshot {
	s := PlacesCallsSnapshot{
		Search:       gps.searchCalls.snapshot(),
		Autocomplete: gps.autocompleteCalls.snapshot(),
		Details:      gps.detailsCalls.snapshot(),
		PhotoLookup:  gps.photoLookupCalls.snapshot(),
		Photo:        gps.photoCalls.snapshot(),
	}
	s.EstPlacesCostUSD = float64(s.Search.Upstream)*placesCostSearchUSDPerCall +
		float64(s.Autocomplete.Upstream)*placesCostAutocompleteUSDPerCall +
		float64(s.Details.Upstream)*placesCostDetailsUSDPerCall +
		float64(s.PhotoLookup.Upstream)*placesCostPhotoLookupUSDPerCall +
		float64(s.Photo.Upstream)*placesCostPhotoUSDPerCall
	return s
}

// MetricsResponse is the Phase 1 dashboard-in-an-endpoint, keyed to the
// questions in docs/business-model.md §8 (activation, second-trip retention,
// attach rate, COGS per active user, cap-hit rate).
type MetricsResponse struct {
	Days int `json:"days"`
	// LandingViews counts anonymous landing_viewed events — the top of the
	// funnel, above signups. Client-guarded to once per app session and
	// strict-rate-limited at ingest, but still an unauthenticated count:
	// read it as directional, not audited.
	LandingViews         int64   `json:"landing_views"`
	Signups              int64   `json:"signups"`
	ActivatedSignups     int64   `json:"activated_signups"`
	ActivationRate       float64 `json:"activation_rate"`
	OnboardingsCompleted int64   `json:"onboardings_completed"`
	TripsCreated         int64   `json:"trips_created"`
	TripsRefined         int64   `json:"trips_refined"`
	// TripsWithBookingClick / AttachRate count DISTINCT non-NULL trip_id on
	// booking_link_clicked. Anonymous clicks always have trip_id NULL (ingest
	// drops it — ownership is unverifiable), so they appear in BookingClicks
	// and ClicksByProvider but can never move the attach rate.
	TripsWithBookingClick int64   `json:"trips_with_booking_click"`
	AttachRate            float64 `json:"attach_rate"`
	// BookingClicks stays the TOTAL (authenticated + anonymous) for backward
	// compatibility; BookingClicksAnonymous is the user_id IS NULL slice —
	// unauthenticated ingest, rate-limit bounded but unaudited, so
	// partner-facing reads should quote total minus anonymous (Wave-8 security
	// review). Same split for ClicksByProvider / ClicksByProviderAnonymous
	// (parallel maps off one grouped query; the anonymous map carries only
	// providers with >= 1 anonymous click).
	BookingClicksAnonymous    int64            `json:"booking_clicks_anonymous"`
	BookingClicks             int64            `json:"booking_clicks"`
	ClicksByProvider          map[string]int64 `json:"clicks_by_provider"`
	ClicksByProviderAnonymous map[string]int64 `json:"clicks_by_provider_anonymous"`
	TodosMarkedBooked         int64            `json:"todos_marked_booked"`
	// SecondTripRetention answers the business model's actual retention
	// question: users who created >= 2 trips at least 7 days apart in the
	// window (the Phase 3 "retention proven across >= 2 trips" trigger).
	SecondTripRetention int64 `json:"second_trip_retention"`
	// SessionFrequencyReturning is the old "returning users" number — plan
	// sessions on >= 2 distinct days. Kept as a session-frequency signal;
	// it is NOT trip retention (hence the rename from returning_users).
	SessionFrequencyReturning int64 `json:"session_frequency_returning"`
	// ActiveUsers is MAU within the window: distinct signed-in users with
	// >= 1 plan_session_started. The COGS-per-user denominator.
	ActiveUsers           int64 `json:"active_users"`
	PlanSessions          int64 `json:"plan_sessions"`
	PlanSessionsAnonymous int64 `json:"plan_sessions_anonymous"`
	// AgentLoopCapHits counts sessions whose agent loop hit the
	// max-iterations safety cap (metadata max_iterations_hit) — a
	// runaway-loop signal, not free-tier pressure. Formerly plan_cap_hits.
	AgentLoopCapHits      int64 `json:"agent_loop_cap_hits"`
	PlanInputTokens       int64 `json:"plan_input_tokens"`
	PlanOutputTokens      int64 `json:"plan_output_tokens"`
	PlanCacheReadTokens   int64 `json:"plan_cache_read_tokens"`
	PlanCacheCreateTokens int64 `json:"plan_cache_creation_tokens"`
	// EstClaudeCostUSD / EstCogsPerActiveUser are ESTIMATES covering Claude
	// spend only, from the planCost* pricing constants. Places spend is
	// estimated separately in PlacesCallsSinceProcessStart (process-lifetime
	// basis, so it cannot be folded into these windowed numbers).
	// EstCostModel names the model whose pricing produced them, so the
	// number is self-describing.
	EstCostModel         string  `json:"est_cost_model"`
	EstClaudeCostUSD     float64 `json:"est_claude_cost_usd"`
	EstCogsPerActiveUser float64 `json:"est_cogs_per_active_user"`
	// FreeCapWouldHits / FreeCapUsersAffected are the §8 cap-hit rate — the
	// Phase-3 demand signal, keyed by cap_kind (plan_runs / active_trips).
	// Would-hits counts crossing events (only-on-crossing, so one per user
	// per crossing — see specs/free-cap-instrumentation); users-affected is
	// the distinct-user cohort, the primary trigger number. Nothing is
	// enforced anywhere — these are measurements of a cap that doesn't exist
	// in code yet.
	FreeCapWouldHits     map[string]int64 `json:"free_cap_would_hits"`
	FreeCapUsersAffected map[string]int64 `json:"free_cap_users_affected"`
	// PlacesCallsSinceProcessStart / EventsCallsSinceProcessStart are
	// PROCESS-LIFETIME provider-call counters: they start at zero on API boot
	// and reset on every restart/deploy. Unlike every field above they are
	// NOT scoped to the Days window — the *_since_process_start names exist
	// so nobody reads them as period metrics. Places carries an estimated
	// upstream cost (COGS visibility); events is quota/cache visibility only
	// (free tier).
	PlacesCallsSinceProcessStart PlacesCallsSnapshot `json:"places_calls_since_process_start"`
	EventsCallsSinceProcessStart UpstreamCallCounts  `json:"events_calls_since_process_start"`
}

// adminMetricsHandler is GET /api/v1/admin/metrics?days= (admin only; gated
// at route registration).
func adminMetricsHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	days := 30
	if d, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && d > 0 && d <= 3650 {
		days = d
	}
	since := time.Now().AddDate(0, 0, -days)
	ctx := r.Context()
	q := store.New(dbPool)

	// One GROUP BY round trip replaces the previous per-type count queries.
	// anonCounts is the same rows' user_id IS NULL slice (a FILTER column,
	// not another query) — today only booking_link_clicked reads it.
	counts := map[string]int64{}
	anonCounts := map[string]int64{}
	if rows, err := q.CountEventsByTypeGrouped(ctx, since); err == nil {
		for _, row := range rows {
			counts[row.EventType] = row.N
			anonCounts[row.EventType] = row.NAnonymous
		}
	} else {
		log.Printf("metrics: grouped counts: %v", err)
	}

	resp := MetricsResponse{
		Days:                      days,
		LandingViews:              counts["landing_viewed"],
		Signups:                   counts["user_registered"],
		OnboardingsCompleted:      counts["onboarding_completed"],
		TripsCreated:              counts["trip_created"],
		TripsRefined:              counts["trip_refined"],
		BookingClicks:             counts["booking_link_clicked"],
		BookingClicksAnonymous:    anonCounts["booking_link_clicked"],
		TodosMarkedBooked:         counts["booking_marked_booked"],
		ClicksByProvider:          map[string]int64{},
		ClicksByProviderAnonymous: map[string]int64{},
		FreeCapWouldHits:          map[string]int64{},
		FreeCapUsersAffected:      map[string]int64{},
	}
	if n, err := q.CountActivatedSignups(ctx, since); err == nil {
		resp.ActivatedSignups = n
	}
	if resp.Signups > 0 {
		resp.ActivationRate = float64(resp.ActivatedSignups) / float64(resp.Signups)
	}
	if n, err := q.CountTripsWithBookingClick(ctx, since); err == nil {
		resp.TripsWithBookingClick = n
	}
	if resp.TripsCreated > 0 {
		resp.AttachRate = float64(resp.TripsWithBookingClick) / float64(resp.TripsCreated)
	}
	if rows, err := q.BookingClicksByProvider(ctx, since); err == nil {
		for _, row := range rows {
			resp.ClicksByProvider[row.Provider] = row.Clicks
			if row.AnonymousClicks > 0 {
				resp.ClicksByProviderAnonymous[row.Provider] = row.AnonymousClicks
			}
		}
	}
	if totals, err := q.PlanSessionTotals(ctx, since); err == nil {
		resp.PlanSessions = totals.Sessions
		resp.PlanSessionsAnonymous = totals.AnonymousSessions
		resp.AgentLoopCapHits = totals.AgentLoopCapHits
		resp.PlanInputTokens = totals.InputTokens
		resp.PlanOutputTokens = totals.OutputTokens
		resp.PlanCacheReadTokens = totals.CacheReadTokens
		resp.PlanCacheCreateTokens = totals.CacheCreationTokens
	}
	if rows, err := q.FreeCapWouldHitCounts(ctx, since); err == nil {
		for _, row := range rows {
			resp.FreeCapWouldHits[row.CapKind] = row.WouldHits
			resp.FreeCapUsersAffected[row.CapKind] = row.UsersAffected
		}
	}
	if eng, err := q.UserEngagementCounts(ctx, since); err == nil {
		resp.ActiveUsers = eng.ActiveUsers
		resp.SessionFrequencyReturning = eng.SessionFrequencyReturning
		resp.SecondTripRetention = eng.SecondTripRetention
	}
	// Estimated Claude spend for the window (Claude only; Places is the
	// separate process-lifetime estimate below). input_tokens is the
	// uncached remainder — cache reads and writes are billed separately at
	// their own rates.
	resp.EstCostModel = planCostModelID
	resp.EstClaudeCostUSD = estClaudeCostUSD(
		resp.PlanInputTokens, resp.PlanOutputTokens,
		resp.PlanCacheCreateTokens, resp.PlanCacheReadTokens)
	if resp.ActiveUsers > 0 {
		resp.EstCogsPerActiveUser = resp.EstClaudeCostUSD / float64(resp.ActiveUsers)
	}
	// Process-lifetime provider-call telemetry (not window-scoped; see the
	// field comments). Read straight off the singletons — no DB involved.
	resp.PlacesCallsSinceProcessStart = placesCallsSnapshot(placesService)
	resp.EventsCallsSinceProcessStart = eventsService.calls.snapshot()
	writeJSON(w, http.StatusOK, resp)
}
