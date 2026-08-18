package main

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

func TestAdminRoutesRequireAdmin(t *testing.T) {
	resetDB(t)
	_, userToken := createTestUser(t, "civilian@example.com")

	paths := []string{
		"/api/v1/admin/metrics",
		"/api/v1/admin/metrics/timeseries",
		"/api/v1/admin/metrics/totals",
		"/api/v1/admin/metrics/activity",
		"/api/v1/admin/metrics/users",
		"/api/v1/admin/local/sources",
		"/api/v1/admin/local/coverage",
		"/api/v1/trips/versions",
	}
	for _, p := range paths {
		if rec := doJSON(t, "GET", p, userToken, nil); rec.Code != http.StatusForbidden {
			t.Fatalf("non-admin GET %s = %d, want 403", p, rec.Code)
		}
		if rec := doJSON(t, "GET", p, "", nil); rec.Code != http.StatusUnauthorized {
			t.Fatalf("anonymous GET %s = %d, want 401", p, rec.Code)
		}
	}
}

func TestAdminMetricsForAdmin(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "admin@example.com")
	makeAdmin(t, admin.ID)

	rec := doJSON(t, "GET", "/api/v1/admin/metrics?days=7", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("admin metrics = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if body["days"] != float64(7) {
		t.Fatalf("days = %v, want 7", body["days"])
	}

	// The process-lifetime provider counters must always be present (they
	// come off in-process singletons, not the DB) under names that say they
	// are NOT window-scoped. Values depend on what earlier tests did to the
	// shared singletons, so assert shape + non-negativity, not exact counts.
	places, ok := body["places_calls_since_process_start"].(map[string]any)
	if !ok {
		t.Fatalf("places_calls_since_process_start missing or not an object: %v", body["places_calls_since_process_start"])
	}
	for _, class := range []string{"search", "autocomplete", "details"} {
		c, ok := places[class].(map[string]any)
		if !ok {
			t.Fatalf("places_calls_since_process_start.%s missing: %v", class, places[class])
		}
		for _, field := range []string{"upstream", "cache_hits"} {
			n, ok := c[field].(float64)
			if !ok || n < 0 {
				t.Fatalf("places %s.%s = %v, want non-negative number", class, field, c[field])
			}
		}
	}
	if cost, ok := places["est_places_cost_usd"].(float64); !ok || cost < 0 {
		t.Fatalf("est_places_cost_usd = %v, want non-negative number", places["est_places_cost_usd"])
	}
	events, ok := body["events_calls_since_process_start"].(map[string]any)
	if !ok {
		t.Fatalf("events_calls_since_process_start missing or not an object: %v", body["events_calls_since_process_start"])
	}
	for _, field := range []string{"upstream", "cache_hits"} {
		if n, ok := events[field].(float64); !ok || n < 0 {
			t.Fatalf("events %s = %v, want non-negative number", field, events[field])
		}
	}
}

// insertEvent writes an analytics event with an explicit created_at so tests
// can shape retention windows (recordEvent always stamps now()).
func insertEvent(t *testing.T, userID uuid.UUID, eventType string, at time.Time, metadata string) {
	t.Helper()
	var meta any
	if metadata != "" {
		meta = metadata
	}
	_, err := dbPool.Exec(context.Background(),
		`INSERT INTO analytics_events (user_id, event_type, metadata, created_at)
		 VALUES ($1, $2, $3, $4)`, userID, eventType, meta, at)
	if err != nil {
		t.Fatalf("insertEvent(%s): %v", eventType, err)
	}
}

// insertAnonymousEvent writes an analytics event with a NULL user_id, the way
// the anonymous /events ingest stores landing_viewed and signed-out
// booking_link_clicked rows.
func insertAnonymousEvent(t *testing.T, eventType string, at time.Time, metadata string) {
	t.Helper()
	var meta any
	if metadata != "" {
		meta = metadata
	}
	_, err := dbPool.Exec(context.Background(),
		`INSERT INTO analytics_events (user_id, event_type, metadata, created_at)
		 VALUES (NULL, $1, $2, $3)`, eventType, meta, at)
	if err != nil {
		t.Fatalf("insertAnonymousEvent(%s): %v", eventType, err)
	}
}

// insertTripCreated writes a trip_created event carrying its trip_id, the way
// plan_handler records it — second_trip_retention dedupes by the referenced
// trip's lineage, so the linkage matters.
func insertTripCreated(t *testing.T, userID, tripID uuid.UUID, at time.Time) {
	t.Helper()
	_, err := dbPool.Exec(context.Background(),
		`INSERT INTO analytics_events (user_id, event_type, trip_id, created_at)
		 VALUES ($1, 'trip_created', $2, $3)`, userID, tripID, at)
	if err != nil {
		t.Fatalf("insertTripCreated: %v", err)
	}
}

// createTripInLineage inserts a bare trips row in the given chat lineage —
// two calls with the same chatID model a version save (one lineage, two
// trip_created events).
func createTripInLineage(t *testing.T, owner uuid.UUID, chatID string) uuid.UUID {
	t.Helper()
	trip, err := store.New(dbPool).CreateTrip(context.Background(), store.CreateTripParams{
		UserID: owner, Title: "Lineage Trip", ChatID: &chatID,
	})
	if err != nil {
		t.Fatalf("createTripInLineage(%s): %v", chatID, err)
	}
	return trip.ID
}

// TestAdminMetricsValues seeds a shaped event log and asserts the grouped
// counts, second-trip retention (≥2 distinct trip LINEAGES with first
// creations ≥7 days apart — version saves of one lineage never count), MAU,
// the Claude cost estimate, and the plan_cap_hits → agent_loop_cap_hits /
// returning_users → session_frequency_returning renames.
func TestAdminMetricsValues(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "admin2@example.com")
	makeAdmin(t, admin.ID)
	userA, _ := createTestUser(t, "retained@example.com")
	userB, _ := createTestUser(t, "notyet@example.com")
	userC, _ := createTestUser(t, "versioner@example.com")

	now := time.Now()
	insertEvent(t, userA.ID, "user_registered", now, "")
	insertEvent(t, userB.ID, "user_registered", now, "")
	insertEvent(t, userC.ID, "user_registered", now, "")

	// A: two DISTINCT lineages 8 days apart => counts toward
	// second_trip_retention.
	insertTripCreated(t, userA.ID, createTripInLineage(t, userA.ID, "chat-a1"), now.AddDate(0, 0, -8))
	insertTripCreated(t, userA.ID, createTripInLineage(t, userA.ID, "chat-a2"), now)
	// B: two distinct lineages only 2 days apart => session enthusiasm, not
	// retention.
	insertTripCreated(t, userB.ID, createTripInLineage(t, userB.ID, "chat-b1"), now.AddDate(0, 0, -2))
	insertTripCreated(t, userB.ID, createTripInLineage(t, userB.ID, "chat-b2"), now)
	// C: two trip_created events 8 days apart but on the SAME lineage (a
	// re-finalized chat, i.e. a version save) => must NOT count as retention.
	insertTripCreated(t, userC.ID, createTripInLineage(t, userC.ID, "chat-c1"), now.AddDate(0, 0, -8))
	insertTripCreated(t, userC.ID, createTripInLineage(t, userC.ID, "chat-c1"), now)

	// A is the sole active (MAU) user; one completed session that hit the
	// agent-loop cap and burned exactly 1M input + 1M output tokens
	// => est cost $3 + $15 = $18, all attributed to the one active user.
	insertEvent(t, userA.ID, "plan_session_started", now, "")
	insertEvent(t, userA.ID, "plan_session_completed", now,
		`{"input_tokens":1000000,"output_tokens":1000000,"cache_read_tokens":0,"cache_creation_tokens":0,"max_iterations_hit":true}`)

	// Top-of-funnel + the booking-click split: one anonymous landing view, one
	// AUTHED booking click and one ANONYMOUS booking click on the same
	// provider. booking_clicks stays the total (2); the anonymous slice (1)
	// must surface in booking_clicks_anonymous and clicks_by_provider_anonymous
	// without disturbing the clicks_by_provider totals.
	insertAnonymousEvent(t, "landing_viewed", now, "")
	insertEvent(t, userA.ID, "booking_link_clicked", now, `{"provider":"duffel"}`)
	insertAnonymousEvent(t, "booking_link_clicked", now, `{"provider":"duffel"}`)

	rec := doJSON(t, "GET", "/api/v1/admin/metrics?days=30", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("admin metrics = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)

	// Grouped per-type counts (one GROUP BY query feeds all of these).
	for field, want := range map[string]float64{
		"signups":                     3,
		"trips_created":               6,
		"landing_views":               1,
		"booking_clicks":              2, // total: 1 authed + 1 anonymous
		"booking_clicks_anonymous":    1,
		"second_trip_retention":       1, // A only: B lacks the 7-day gap, C's gap is within one lineage
		"session_frequency_returning": 0, // A's sessions all on one day
		"active_users":                1,
		"plan_sessions":               1,
		"agent_loop_cap_hits":         1,
		"plan_input_tokens":           1000000,
		"plan_output_tokens":          1000000,
		"est_claude_cost_usd":         18,
		"est_cogs_per_active_user":    18,
	} {
		if body[field] != want {
			t.Errorf("%s = %v, want %v", field, body[field], want)
		}
	}

	if body["est_cost_model"] != "claude-sonnet-4-6" {
		t.Errorf("est_cost_model = %v, want claude-sonnet-4-6", body["est_cost_model"])
	}

	// Per-provider split: totals keep counting everyone; the anonymous map is
	// the user_id IS NULL slice of the SAME grouped query (no extra round
	// trip — the dashboard load must stay at 7 queries).
	if byProvider, ok := body["clicks_by_provider"].(map[string]any); !ok || byProvider["duffel"] != float64(2) {
		t.Errorf("clicks_by_provider = %v, want duffel: 2", body["clicks_by_provider"])
	}
	if anon, ok := body["clicks_by_provider_anonymous"].(map[string]any); !ok || anon["duffel"] != float64(1) {
		t.Errorf("clicks_by_provider_anonymous = %v, want duffel: 1", body["clicks_by_provider_anonymous"])
	}

	// The old, misleading field names must be gone.
	for _, gone := range []string{"plan_cap_hits", "returning_users"} {
		if _, ok := body[gone]; ok {
			t.Errorf("response still contains renamed field %q", gone)
		}
	}
}

// TestAdminTimeseries seeds events across the window boundary and asserts the
// UTC day buckets, the fixed series keys (all present, empty arrays included),
// and window exclusion.
func TestAdminTimeseries(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "ts-admin@example.com")
	makeAdmin(t, admin.ID)
	user, _ := createTestUser(t, "ts-user@example.com")

	now := time.Now().UTC()
	insertEvent(t, user.ID, "user_registered", now, "")
	insertEvent(t, user.ID, "trip_created", now.AddDate(0, 0, -2), "")
	insertEvent(t, user.ID, "trip_created", now.AddDate(0, 0, -2), "")
	// Outside the 7-day window — must not appear.
	insertEvent(t, user.ID, "trip_created", now.AddDate(0, 0, -40), "")
	// Not in timeseriesEventTypes — must not create a series key.
	insertEvent(t, user.ID, "trip_refined", now, "")

	rec := doJSON(t, "GET", "/api/v1/admin/metrics/timeseries?days=7", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("timeseries = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if body["days"] != float64(7) {
		t.Fatalf("days = %v, want 7", body["days"])
	}
	series, ok := body["series"].(map[string]any)
	if !ok {
		t.Fatalf("series missing: %v", body["series"])
	}
	for _, key := range []string{"landing_viewed", "landing_prompt_submitted",
		"user_registered", "trip_created", "plan_session_started",
		"booking_link_clicked", "itinerary_item_added"} {
		if _, ok := series[key]; !ok {
			t.Errorf("series[%s] missing (stable slots require every type)", key)
		}
	}
	if _, ok := series["trip_refined"]; ok {
		t.Errorf("series contains trip_refined, which is not a dashboard series")
	}

	buckets := func(key string) []any {
		s, _ := series[key].([]any)
		return s
	}
	reg := buckets("user_registered")
	if len(reg) != 1 {
		t.Fatalf("user_registered buckets = %v, want 1", reg)
	}
	if b := reg[0].(map[string]any); b["day"] != now.Format("2006-01-02") || b["n"] != float64(1) {
		t.Errorf("user_registered bucket = %v, want {%s 1}", b, now.Format("2006-01-02"))
	}
	tc := buckets("trip_created")
	if len(tc) != 1 {
		t.Fatalf("trip_created buckets = %v, want 1 (the -40d event must be excluded)", tc)
	}
	wantDay := now.AddDate(0, 0, -2).Format("2006-01-02")
	if b := tc[0].(map[string]any); b["day"] != wantDay || b["n"] != float64(2) {
		t.Errorf("trip_created bucket = %v, want {%s 2}", b, wantDay)
	}
	if lv := buckets("landing_viewed"); len(lv) != 0 {
		t.Errorf("landing_viewed = %v, want empty array", lv)
	}
}

// TestAdminTotals seeds every counted table, including rows the WHERE filters
// must exclude (cancelled alert, revoked share/collaborator, draft rec).
func TestAdminTotals(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "totals-admin@example.com")
	makeAdmin(t, admin.ID)
	user, _ := createTestUser(t, "totals-user@example.com")

	ctx := context.Background()
	mustExec := func(sql string, args ...any) {
		t.Helper()
		if _, err := dbPool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("seed: %v (%s)", err, sql)
		}
	}

	mustExec(`UPDATE users SET email_verified_at = now(), onboarded_at = now() WHERE id = $1`, user.ID)

	// 3 trips across 2 lineages (l1 has a version save).
	t1 := createTripInLineage(t, user.ID, "totals-l1")
	createTripInLineage(t, user.ID, "totals-l1")
	createTripInLineage(t, user.ID, "totals-l2")
	mustExec(`INSERT INTO itinerary_items (trip_id, position, name, latitude, longitude)
	          VALUES ($1, 0, 'Museum', 0, 0)`, t1)
	mustExec(`INSERT INTO booking_todos (trip_id, kind, todo_key, title)
	          VALUES ($1, 'stay', 'stay:x', 'Stay in X')`, t1)
	mustExec(`INSERT INTO local_sources (name) VALUES ('Test Local')`)
	mustExec(`INSERT INTO local_recommendations (source_id, city, name, status)
	          SELECT id, 'Athens', 'Published Spot', 'published' FROM local_sources LIMIT 1`)
	mustExec(`INSERT INTO local_recommendations (source_id, city, name, status)
	          SELECT id, 'Athens', 'Draft Spot', 'draft' FROM local_sources LIMIT 1`)
	mustExec(`INSERT INTO trip_shares (chat_id, owner_id, token) VALUES ('totals-l1', $1, 'tok-active')`, user.ID)
	mustExec(`INSERT INTO trip_shares (chat_id, owner_id, token, revoked_at)
	          VALUES ('totals-l1', $1, 'tok-revoked', now())`, user.ID)
	mustExec(`INSERT INTO trip_collaborators (chat_id, owner_id, user_id) VALUES ('totals-l1', $1, $2)`, user.ID, admin.ID)
	mustExec(`INSERT INTO trip_collaborators (chat_id, owner_id, user_id, revoked_at)
	          VALUES ('totals-l2', $1, $2, now())`, user.ID, admin.ID)
	insertEvent(t, user.ID, "trip_created", time.Now(), "")

	rec := doJSON(t, "GET", "/api/v1/admin/metrics/totals", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("totals = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	for field, want := range map[string]float64{
		"users":                2,
		"verified_users":       1,
		"onboarded_users":      1,
		"trips":                3,
		"trip_lineages":        2,
		"itinerary_items":      1,
		"booking_todos":        1,
		"published_local_recs": 1, // draft excluded
		"local_guides":         0,
		"active_collaborators": 1, // revoked excluded
		"active_shares":        1, // revoked excluded
		"active_sessions":      2, // one per createTestUser
		"analytics_events":     1,
	} {
		if body[field] != want {
			t.Errorf("%s = %v, want %v", field, body[field], want)
		}
	}
}

// TestAdminActivity asserts DESC ordering, the anonymous null-email contract,
// metadata passthrough, and keyset pagination via next_before.
func TestAdminActivity(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "act-admin@example.com")
	makeAdmin(t, admin.ID)
	user, _ := createTestUser(t, "act-user@example.com")

	now := time.Now()
	insertEvent(t, user.ID, "user_registered", now.Add(-3*time.Minute), "")
	insertAnonymousEvent(t, "booking_link_clicked", now.Add(-2*time.Minute), `{"provider":"duffel"}`)
	insertEvent(t, user.ID, "trip_created", now.Add(-1*time.Minute), "")

	rec := doJSON(t, "GET", "/api/v1/admin/metrics/activity?limit=2", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("activity = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	events, _ := body["events"].([]any)
	if len(events) != 2 {
		t.Fatalf("events = %d, want 2 (limit)", len(events))
	}

	first := events[0].(map[string]any)
	second := events[1].(map[string]any)
	if first["event_type"] != "trip_created" || second["event_type"] != "booking_link_clicked" {
		t.Fatalf("order = %v, %v — want trip_created then booking_link_clicked (DESC)",
			first["event_type"], second["event_type"])
	}
	if first["user_email"] != "act-user@example.com" {
		t.Errorf("authed user_email = %v, want act-user@example.com", first["user_email"])
	}
	if second["user_email"] != nil {
		t.Errorf("anonymous user_email = %v, want null", second["user_email"])
	}
	meta, _ := second["metadata"].(map[string]any)
	if meta["provider"] != "duffel" {
		t.Errorf("metadata = %v, want provider duffel", second["metadata"])
	}

	// Page 2 via the cursor: only the oldest event remains.
	cursor, _ := body["next_before"].(string)
	if cursor == "" {
		t.Fatalf("next_before missing on a full page")
	}
	rec = doJSON(t, "GET", "/api/v1/admin/metrics/activity?limit=2&before="+url.QueryEscape(cursor), adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("activity page 2 = %d: %s", rec.Code, rec.Body.String())
	}
	body = decode(t, rec)
	events, _ = body["events"].([]any)
	if len(events) != 1 || events[0].(map[string]any)["event_type"] != "user_registered" {
		t.Fatalf("page 2 = %v, want just user_registered", events)
	}
	if nb, ok := body["next_before"]; ok {
		t.Errorf("short page still has next_before = %v", nb)
	}

	rec = doJSON(t, "GET", "/api/v1/admin/metrics/activity?before=not-a-time", adminToken, nil)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("bad before = %d, want 400", rec.Code)
	}
}

// TestAdminActivityExcludeAdmins asserts exclude_admins=true drops rows from
// admin users (the operator's own clicks) while keeping normal-user and
// anonymous rows, and that the default omits the filter (backward compatible).
func TestAdminActivityExcludeAdmins(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "excl-admin@example.com")
	makeAdmin(t, admin.ID)
	user, _ := createTestUser(t, "excl-user@example.com")

	now := time.Now()
	insertEvent(t, user.ID, "user_registered", now.Add(-3*time.Minute), "")
	insertAnonymousEvent(t, "booking_link_clicked", now.Add(-2*time.Minute), "")
	insertEvent(t, admin.ID, "trip_created", now.Add(-1*time.Minute), "")

	// Default (exclude_admins absent) returns all three, admin's included.
	body := decode(t, doJSON(t, "GET", "/api/v1/admin/metrics/activity?limit=50", adminToken, nil))
	events, _ := body["events"].([]any)
	if len(events) != 3 {
		t.Fatalf("default events = %d, want 3 (admin row included)", len(events))
	}

	// exclude_admins=true drops only the admin's row; user + anonymous survive.
	body = decode(t, doJSON(t, "GET", "/api/v1/admin/metrics/activity?limit=50&exclude_admins=true", adminToken, nil))
	events, _ = body["events"].([]any)
	if len(events) != 2 {
		t.Fatalf("exclude_admins events = %d, want 2 (admin row omitted)", len(events))
	}
	for _, e := range events {
		ev := e.(map[string]any)
		if ev["user_is_admin"] == true {
			t.Errorf("exclude_admins returned an admin row: %v", ev["event_type"])
		}
		if ev["event_type"] == "trip_created" {
			t.Errorf("admin's trip_created row leaked into exclude_admins result")
		}
	}
}

// TestAdminUsers asserts the per-user aggregates (lineage-deduped trips, token
// sums with the plan_session_completed filter, cost estimate), the
// last_event_at DESC NULLS LAST ordering, and offset paging.
func TestAdminUsers(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "users-admin@example.com")
	makeAdmin(t, admin.ID)
	active, _ := createTestUser(t, "users-active@example.com")
	dormant, _ := createTestUser(t, "users-dormant@example.com")
	_ = dormant

	now := time.Now()
	// 3 trips across 2 lineages; the same 1M/1M token fixture as
	// TestAdminMetricsValues => est cost $18.
	createTripInLineage(t, active.ID, "users-l1")
	createTripInLineage(t, active.ID, "users-l1")
	createTripInLineage(t, active.ID, "users-l2")
	insertEvent(t, active.ID, "plan_session_started", now.Add(-time.Hour), "")
	insertEvent(t, active.ID, "plan_session_completed", now.Add(-time.Hour),
		`{"input_tokens":1000000,"output_tokens":1000000,"cache_read_tokens":0,"cache_creation_tokens":0}`)
	// Same metadata keys on a different event type must NOT be summed.
	insertEvent(t, active.ID, "booking_link_clicked", now, `{"provider":"duffel"}`)

	rec := doJSON(t, "GET", "/api/v1/admin/metrics/users", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("users = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if body["total"] != float64(3) {
		t.Fatalf("total = %v, want 3", body["total"])
	}
	users, _ := body["users"].([]any)
	if len(users) != 3 {
		t.Fatalf("users len = %d, want 3", len(users))
	}

	// active has events => sorts first; the two event-less users follow by
	// created_at DESC (dormant was created after admin).
	first := users[0].(map[string]any)
	if first["email"] != "users-active@example.com" {
		t.Fatalf("first user = %v, want the active one (NULLS LAST)", first["email"])
	}
	for field, want := range map[string]float64{
		"trips":               3,
		"trip_lineages":       2,
		"plan_sessions":       1,
		"booking_clicks":      1,
		"plan_input_tokens":   1000000,
		"plan_output_tokens":  1000000,
		"est_claude_cost_usd": 18,
	} {
		if first[field] != want {
			t.Errorf("active.%s = %v, want %v", field, first[field], want)
		}
	}
	if first["last_event_at"] == nil {
		t.Errorf("active.last_event_at is null, want set")
	}
	if first["is_admin"] != false {
		t.Errorf("active.is_admin = %v, want false", first["is_admin"])
	}
	if users[1].(map[string]any)["last_event_at"] != nil {
		t.Errorf("event-less user has last_event_at = %v, want null", users[1].(map[string]any)["last_event_at"])
	}
	adminRow := users[2].(map[string]any)
	if adminRow["email"] != "users-admin@example.com" || adminRow["is_admin"] != true {
		t.Errorf("last row = %v/%v, want the admin with is_admin true", adminRow["email"], adminRow["is_admin"])
	}

	// Offset paging: skip the active user, keep the rest of the order.
	rec = doJSON(t, "GET", "/api/v1/admin/metrics/users?limit=1&offset=1", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("users offset = %d: %s", rec.Code, rec.Body.String())
	}
	body = decode(t, rec)
	users, _ = body["users"].([]any)
	if len(users) != 1 || users[0].(map[string]any)["email"] != "users-dormant@example.com" {
		t.Fatalf("offset page = %v, want just users-dormant", users)
	}
}
