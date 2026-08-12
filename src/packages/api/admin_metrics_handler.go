package main

// Admin analytics dashboard extensions: four read-only rollup endpoints next
// to /admin/metrics (all admin-gated at route registration, all 503 in
// degraded mode like adminMetricsHandler):
//
//	GET /admin/metrics/timeseries?days=   — daily buckets for the Trends tab
//	GET /admin/metrics/totals             — all-time domain-table counts
//	GET /admin/metrics/activity?limit=&before=&exclude_admins= — event tail, keyset-paginated
//	GET /admin/metrics/users?limit=&offset=    — per-user activity aggregates
//
// Deliberately NOT folded into MetricsResponse: totals is not window-scoped,
// activity/users need pagination params, and the tabbed dashboard lazy-loads
// each pane independently.

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// timeseriesEventTypes is the fixed set of daily series the Trends tab
// renders, top-of-funnel to bottom. Every type is always present in the
// response (empty array included) so the client gets stable chart slots.
var timeseriesEventTypes = []string{
	"landing_viewed",
	"user_registered",
	"trip_created",
	"plan_session_started",
	"booking_link_clicked",
	"itinerary_item_added",
}

// metricsDaysParam clamps ?days= exactly like adminMetricsHandler.
func metricsDaysParam(r *http.Request) int {
	days := 30
	if d, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && d > 0 && d <= 3650 {
		days = d
	}
	return days
}

// pageLimitParam clamps ?limit= to (0, cap], defaulting to def.
func pageLimitParam(r *http.Request, def, cap int) int {
	limit := def
	if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 {
		limit = min(l, cap)
	}
	return limit
}

type dailyCount struct {
	Day string `json:"day"` // YYYY-MM-DD, UTC bucket
	N   int64  `json:"n"`
}

type timeseriesResponse struct {
	Days     int    `json:"days"`
	StartDay string `json:"start_day"` // first day of the window, YYYY-MM-DD UTC
	// Series is keyed by event_type verbatim; sparse per day (the client
	// fills zero days from start_day + days).
	Series map[string][]dailyCount `json:"series"`
}

// adminTimeseriesHandler is GET /admin/metrics/timeseries?days=.
func adminTimeseriesHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	days := metricsDaysParam(r)
	// Align the window to UTC midnight so buckets are whole days: a "7 days"
	// window is today plus the 6 prior calendar days, not a 168-hour slice.
	startDay := time.Now().UTC().Truncate(24*time.Hour).AddDate(0, 0, -(days - 1))

	q := store.New(dbPool)
	rows, err := q.EventDailyCounts(r.Context(), store.EventDailyCountsParams{
		Since:      startDay,
		EventTypes: timeseriesEventTypes,
	})
	if err != nil {
		log.Printf("admin timeseries: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "query failed")
		return
	}

	resp := timeseriesResponse{
		Days:     days,
		StartDay: startDay.Format("2006-01-02"),
		Series:   make(map[string][]dailyCount, len(timeseriesEventTypes)),
	}
	for _, t := range timeseriesEventTypes {
		resp.Series[t] = []dailyCount{}
	}
	for _, row := range rows {
		resp.Series[row.EventType] = append(resp.Series[row.EventType], dailyCount{
			Day: row.Day.Time.Format("2006-01-02"),
			N:   row.N,
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

// adminTotalsHandler is GET /admin/metrics/totals. The sqlc row's JSON tags
// are the contract (snake_case aliases we control in query/admin.sql), so it
// serializes directly.
func adminTotalsHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	totals, err := store.New(dbPool).AdminTotals(r.Context())
	if err != nil {
		log.Printf("admin totals: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "query failed")
		return
	}
	writeJSON(w, http.StatusOK, totals)
}

type activityEvent struct {
	ID        uuid.UUID `json:"id"`
	EventType string    `json:"event_type"`
	// UserEmail is null for anonymous events (user_id NULL at ingest), keyed
	// off user_id validity — an empty email never means anonymous.
	UserEmail   *string         `json:"user_email"`
	UserIsAdmin bool            `json:"user_is_admin"`
	TripID      *uuid.UUID      `json:"trip_id"`
	Metadata    json.RawMessage `json:"metadata"` // sanitized at ingest; echoed verbatim
	CreatedAt   time.Time       `json:"created_at"`
}

type activityResponse struct {
	Events []activityEvent `json:"events"`
	// NextBefore is the cursor for the next page (last row's created_at),
	// empty when this page is short — i.e. there is no next page.
	NextBefore string `json:"next_before,omitempty"`
}

// adminActivityHandler is GET /admin/metrics/activity?limit=&before=&exclude_admins=.
func adminActivityHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	limit := pageLimitParam(r, 50, 200)
	before := time.Now()
	if b := r.URL.Query().Get("before"); b != "" {
		t, err := time.Parse(time.RFC3339Nano, b)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "before must be RFC3339")
			return
		}
		before = t
	}

	// exclude_admins=true drops the operator's own activity so the funnel/feed
	// reflects real users; default false keeps the existing behavior.
	excludeAdmins := r.URL.Query().Get("exclude_admins") == "true"

	rows, err := store.New(dbPool).RecentAnalyticsEvents(r.Context(), store.RecentAnalyticsEventsParams{
		Before:        before,
		ExcludeAdmins: excludeAdmins,
		PageLimit:     int32(limit),
	})
	if err != nil {
		log.Printf("admin activity: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "query failed")
		return
	}

	resp := activityResponse{Events: make([]activityEvent, 0, len(rows))}
	for _, row := range rows {
		ev := activityEvent{
			ID:          row.ID,
			EventType:   row.EventType,
			UserIsAdmin: row.UserIsAdmin,
			CreatedAt:   row.CreatedAt,
		}
		if row.UserID.Valid {
			email := row.UserEmail
			ev.UserEmail = &email
		}
		if row.TripID.Valid {
			tid := uuid.UUID(row.TripID.Bytes)
			ev.TripID = &tid
		}
		if len(row.Metadata) > 0 {
			ev.Metadata = json.RawMessage(row.Metadata)
		}
		resp.Events = append(resp.Events, ev)
	}
	if len(rows) == limit {
		resp.NextBefore = rows[len(rows)-1].CreatedAt.Format(time.RFC3339Nano)
	}
	writeJSON(w, http.StatusOK, resp)
}

type adminUserRow struct {
	ID                      uuid.UUID  `json:"id"`
	Email                   string     `json:"email"`
	DisplayName             *string    `json:"display_name"`
	IsAdmin                 bool       `json:"is_admin"`
	SignedUpAt              time.Time  `json:"signed_up_at"`
	Onboarded               bool       `json:"onboarded"`
	EmailVerified           bool       `json:"email_verified"`
	Trips                   int64      `json:"trips"`
	TripLineages            int64      `json:"trip_lineages"`
	PlanSessions            int64      `json:"plan_sessions"`
	BookingClicks           int64      `json:"booking_clicks"`
	PlanInputTokens         int64      `json:"plan_input_tokens"`
	PlanOutputTokens        int64      `json:"plan_output_tokens"`
	PlanCacheReadTokens     int64      `json:"plan_cache_read_tokens"`
	PlanCacheCreationTokens int64      `json:"plan_cache_creation_tokens"`
	EstClaudeCostUSD        float64    `json:"est_claude_cost_usd"`
	LastEventAt             *time.Time `json:"last_event_at"`
}

type adminUsersResponse struct {
	Total int64          `json:"total"`
	Users []adminUserRow `json:"users"`
}

// adminUsersHandler is GET /admin/metrics/users?limit=&offset=.
func adminUsersHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	limit := pageLimitParam(r, 50, 200)
	offset := 0
	if o, err := strconv.Atoi(r.URL.Query().Get("offset")); err == nil && o > 0 {
		offset = o
	}

	ctx := r.Context()
	q := store.New(dbPool)
	total, err := q.CountUsers(ctx)
	if err != nil {
		log.Printf("admin users: count: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "query failed")
		return
	}
	rows, err := q.AdminUserActivity(ctx, store.AdminUserActivityParams{
		Limit:  int32(limit),
		Offset: int32(offset),
	})
	if err != nil {
		log.Printf("admin users: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "query failed")
		return
	}

	resp := adminUsersResponse{Total: total, Users: make([]adminUserRow, 0, len(rows))}
	for _, row := range rows {
		u := adminUserRow{
			ID:                      row.ID,
			Email:                   row.Email,
			DisplayName:             row.DisplayName,
			IsAdmin:                 row.IsAdmin,
			SignedUpAt:              row.SignedUpAt,
			Onboarded:               row.Onboarded,
			EmailVerified:           row.EmailVerified,
			Trips:                   row.Trips,
			TripLineages:            row.TripLineages,
			PlanSessions:            row.PlanSessions,
			BookingClicks:           row.BookingClicks,
			PlanInputTokens:         row.PlanInputTokens,
			PlanOutputTokens:        row.PlanOutputTokens,
			PlanCacheReadTokens:     row.PlanCacheReadTokens,
			PlanCacheCreationTokens: row.PlanCacheCreationTokens,
			// Same pricing basis as MetricsResponse.EstClaudeCostUSD — the
			// planCost* constants pinned to the /plan model.
			EstClaudeCostUSD: estClaudeCostUSD(
				row.PlanInputTokens, row.PlanOutputTokens,
				row.PlanCacheCreationTokens, row.PlanCacheReadTokens),
		}
		// max(created_at) through a LEFT JOIN: sqlc types it interface{};
		// pgx delivers time.Time or nil.
		if t, ok := row.LastEventAt.(time.Time); ok {
			u.LastEventAt = &t
		}
		resp.Users = append(resp.Users, u)
	}
	writeJSON(w, http.StatusOK, resp)
}
