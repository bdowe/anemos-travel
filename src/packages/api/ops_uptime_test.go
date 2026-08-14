package main

// Pure rollup tests for the uptime history (specs/uptime-history) — literal
// fixtures, no DB. The fixtures pin the attribution table in rowVerdicts and
// the day accounting in rollupUptime, including the two invariants the whole
// feature hangs on: a deploy gap never dents a percentage, and backups can
// never touch the API bar.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"travel-route-planner/store"
)

var uptimeDay0 = time.Date(2026, 8, 10, 0, 0, 0, 0, time.UTC)

func tickAt(coversFrom, observedAt time.Time, dbOK, aiOK, backupsOK bool) store.HealthSamplesSinceRow {
	return store.HealthSamplesSinceRow{
		ObservedAt: observedAt,
		CoversFrom: coversFrom,
		Kind:       healthSampleTick,
		DbOk:       &dbOK,
		AiOk:       &aiOK,
		BackupsOk:  &backupsOK,
	}
}

func gapAt(coversFrom, observedAt time.Time, cause string) store.HealthSamplesSinceRow {
	return store.HealthSamplesSinceRow{
		ObservedAt: observedAt,
		CoversFrom: coversFrom,
		Kind:       healthSampleGap,
		GapCause:   &cause,
	}
}

// rollup3 runs a 3-day window (day0..day0+2) with now = noon on the last day.
func rollup3(rows []store.HealthSamplesSinceRow) UptimeResponse {
	now := uptimeDay0.AddDate(0, 0, 2).Add(12 * time.Hour)
	return rollupUptime(rows, uptimeDay0, 3, now, nil, 15*time.Minute)
}

func comp(t *testing.T, resp UptimeResponse, key string) UptimeComponent {
	t.Helper()
	for _, c := range resp.Components {
		if c.Key == key {
			return c
		}
	}
	t.Fatalf("component %q missing from response", key)
	return UptimeComponent{}
}

func wantPct(t *testing.T, got *float64, want float64, label string) {
	t.Helper()
	if got == nil {
		t.Fatalf("%s: uptime_pct nil, want %v", label, want)
	}
	if *got != want {
		t.Fatalf("%s: uptime_pct = %v, want %v", label, *got, want)
	}
}

// No samples at all: every day of every component is no_data with a NULL
// percentage — never an invented 0%% or 100%% — and unknown_s accounts for the
// full elapsed time (partial for today).
func TestRollupEmpty(t *testing.T) {
	resp := rollup3(nil)
	if len(resp.Components) != uptimeCompCount {
		t.Fatalf("components = %d, want %d", len(resp.Components), uptimeCompCount)
	}
	for _, c := range resp.Components {
		if len(c.Days) != 3 {
			t.Fatalf("%s: days = %d, want 3 (dense)", c.Key, len(c.Days))
		}
		if c.UptimePct != nil {
			t.Fatalf("%s: window pct = %v, want nil", c.Key, *c.UptimePct)
		}
		if c.ObservedDays != 0 || c.Status != uptimeStateNoData {
			t.Fatalf("%s: observed_days=%d status=%s, want 0/no_data", c.Key, c.ObservedDays, c.Status)
		}
		for i, d := range c.Days {
			if d.State != uptimeStateNoData || d.UptimePct != nil {
				t.Fatalf("%s day %d: state=%s pct=%v, want no_data/nil", c.Key, i, d.State, d.UptimePct)
			}
			wantUnknown := int64(86400)
			if i == 2 {
				wantUnknown = 43200 // today: only elapsed time is accounted for
			}
			if d.UnknownS != wantUnknown {
				t.Fatalf("%s day %d: unknown_s=%d, want %d", c.Key, i, d.UnknownS, wantUnknown)
			}
		}
	}
}

// A fully green observed day is 100%%, state up, zero unknown.
func TestRollupFullGreenDay(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.AddDate(0, 0, 1), true, true, true),
	}
	resp := rollup3(rows)
	d := comp(t, resp, "api").Days[0]
	if d.State != uptimeStateUp || d.UpS != 86400 || d.DownS != 0 || d.UnknownS != 0 {
		t.Fatalf("day0 = %+v, want up/86400/0/0", d)
	}
	wantPct(t, d.UptimePct, 100, "api day0")
	if len(d.ReasonCodes) != 0 {
		t.Fatalf("green day carries reasons: %v", d.ReasonCodes)
	}
	if comp(t, resp, "api").ObservedDays != 1 {
		t.Fatalf("observed_days = %d, want 1", comp(t, resp, "api").ObservedDays)
	}
}

// A DB outage moves the api AND database rows together (the documented
// containment) and leaves ai/backups untouched.
func TestRollupDBOutageContainment(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.Add(20*time.Hour), true, true, true),
		tickAt(uptimeDay0.Add(20*time.Hour), uptimeDay0.AddDate(0, 0, 1), false, true, true),
	}
	resp := rollup3(rows)
	for _, key := range []string{"api", "database"} {
		d := comp(t, resp, key).Days[0]
		if d.DownS != 4*3600 || d.UpS != 20*3600 {
			t.Fatalf("%s day0: up=%d down=%d, want 72000/14400", key, d.UpS, d.DownS)
		}
		if d.State != uptimeStateDown { // 83.33% < degradedPctFloor
			t.Fatalf("%s day0 state = %s, want down", key, d.State)
		}
		wantPct(t, d.UptimePct, 83.33, key+" day0")
		if len(d.ReasonCodes) != 1 || d.ReasonCodes[0] != uptimeReasonDBUnreachable {
			t.Fatalf("%s day0 reasons = %v", key, d.ReasonCodes)
		}
	}
	for _, key := range []string{"ai_provider", "backups"} {
		d := comp(t, resp, key).Days[0]
		if d.State != uptimeStateUp || d.DownS != 0 {
			t.Fatalf("%s day0 = %+v, want untouched (up)", key, d)
		}
	}
}

// THE deploy invariant: a deploy gap is unobserved time — the percentage does
// not move, for any component, and the day stays "up".
func TestRollupDeployGapDoesNotDent(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.Add(10*time.Hour), true, true, true),
		gapAt(uptimeDay0.Add(10*time.Hour), uptimeDay0.Add(10*time.Hour+10*time.Minute), healthGapDeploy),
		tickAt(uptimeDay0.Add(10*time.Hour+10*time.Minute), uptimeDay0.AddDate(0, 0, 1), true, true, true),
	}
	resp := rollup3(rows)
	for _, c := range resp.Components {
		d := c.Days[0]
		if d.State != uptimeStateUp || d.DownS != 0 {
			t.Fatalf("%s day0 after deploy gap = %+v, want up/0 down", c.Key, d)
		}
		wantPct(t, d.UptimePct, 100, c.Key+" day0")
		if d.UnknownS != 600 {
			t.Fatalf("%s day0 unknown_s = %d, want 600", c.Key, d.UnknownS)
		}
	}
}

// An UNEXPLAINED gap (crash/OOM/host reboot) is downtime — but only on the
// api row; nothing was observed about the other components.
func TestRollupUnexplainedGapIsDowntime(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.Add(10*time.Hour), true, true, true),
		gapAt(uptimeDay0.Add(10*time.Hour), uptimeDay0.Add(10*time.Hour+10*time.Minute), healthGapUnknown),
		tickAt(uptimeDay0.Add(10*time.Hour+10*time.Minute), uptimeDay0.AddDate(0, 0, 1), true, true, true),
	}
	resp := rollup3(rows)

	api := comp(t, resp, "api").Days[0]
	if api.DownS != 600 {
		t.Fatalf("api day0 down_s = %d, want 600", api.DownS)
	}
	if api.State != uptimeStateDegraded { // 99.31% >= floor: a blip, not an outage
		t.Fatalf("api day0 state = %s, want degraded", api.State)
	}
	wantPct(t, api.UptimePct, 99.31, "api day0")
	if len(api.ReasonCodes) != 1 || api.ReasonCodes[0] != uptimeReasonProcessDown {
		t.Fatalf("api day0 reasons = %v, want [process_down]", api.ReasonCodes)
	}

	db := comp(t, resp, "database").Days[0]
	if db.DownS != 0 || db.UnknownS != 600 {
		t.Fatalf("database day0 down=%d unknown=%d, want 0/600", db.DownS, db.UnknownS)
	}
	wantPct(t, db.UptimePct, 100, "database day0")
}

// A gap crossing UTC midnight splits its downtime across both days.
func TestRollupMidnightCrossingGap(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.Add(23*time.Hour), true, true, true),
		gapAt(uptimeDay0.Add(23*time.Hour), uptimeDay0.Add(25*time.Hour), healthGapUnknown),
	}
	resp := rollup3(rows)
	api := comp(t, resp, "api")
	if api.Days[0].DownS != 3600 || api.Days[1].DownS != 3600 {
		t.Fatalf("midnight split: day0 down=%d day1 down=%d, want 3600/3600",
			api.Days[0].DownS, api.Days[1].DownS)
	}
}

// THE backups isolation invariant: a whole day of stale backups moves ONLY the
// backups row; the api row still reads 100%%. (Same shape pins ai_provider.)
func TestRollupBackupsCannotTouchAvailability(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.AddDate(0, 0, 1), true, true, false),
	}
	resp := rollup3(rows)

	backups := comp(t, resp, "backups").Days[0]
	if backups.State != uptimeStateDown || backups.DownS != 86400 {
		t.Fatalf("backups day0 = %+v, want down/86400", backups)
	}
	wantPct(t, backups.UptimePct, 0, "backups day0")
	if len(backups.ReasonCodes) != 1 || backups.ReasonCodes[0] != uptimeReasonBackupsStale {
		t.Fatalf("backups day0 reasons = %v", backups.ReasonCodes)
	}

	for _, key := range []string{"api", "database", "ai_provider"} {
		d := comp(t, resp, key).Days[0]
		if d.State != uptimeStateUp || d.DownS != 0 {
			t.Fatalf("%s day0 tinted by stale backups: %+v", key, d)
		}
		wantPct(t, d.UptimePct, 100, key+" day0")
	}
}

// An AI-provider failure moves only the ai_provider row.
func TestRollupAIFailureIsolated(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.AddDate(0, 0, 1), true, false, true),
	}
	resp := rollup3(rows)
	ai := comp(t, resp, "ai_provider").Days[0]
	if ai.State != uptimeStateDown || ai.ReasonCodes[0] != uptimeReasonAIFailing {
		t.Fatalf("ai_provider day0 = %+v", ai)
	}
	if d := comp(t, resp, "api").Days[0]; d.State != uptimeStateUp {
		t.Fatalf("api day0 tinted by AI failure: %+v", d)
	}
}

// The anchor row from before the window is clipped to the window's start —
// it fills day zero's opening minutes without leaking pre-window seconds.
func TestRollupAnchorClipsToWindow(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0.Add(-2*time.Hour), uptimeDay0.Add(1*time.Hour), true, true, true),
	}
	resp := rollup3(rows)
	d := comp(t, resp, "api").Days[0]
	if d.UpS != 3600 {
		t.Fatalf("anchor clip: day0 up_s = %d, want 3600", d.UpS)
	}
}

// Overlapping rows (a buffer flush racing a live tick) cannot double-count:
// the walk clips each row to start no earlier than the previous row's end.
func TestRollupOverlapDefense(t *testing.T) {
	rows := []store.HealthSamplesSinceRow{
		tickAt(uptimeDay0, uptimeDay0.Add(2*time.Hour), true, true, true),
		tickAt(uptimeDay0.Add(1*time.Hour), uptimeDay0.Add(3*time.Hour), true, true, true),
	}
	resp := rollup3(rows)
	d := comp(t, resp, "api").Days[0]
	if d.UpS != 3*3600 {
		t.Fatalf("overlap: day0 up_s = %d, want %d", d.UpS, 3*3600)
	}
}

// Today's tail past `now` is counted nowhere: a green morning is 100%% up with
// zero unknown, not penalized for the afternoon that hasn't happened.
func TestRollupTodayPartial(t *testing.T) {
	day2 := uptimeDay0.AddDate(0, 0, 2)
	rows := []store.HealthSamplesSinceRow{
		tickAt(day2, day2.Add(12*time.Hour), true, true, true), // exactly up to now
	}
	resp := rollup3(rows)
	d := comp(t, resp, "api").Days[2]
	if d.UpS != 43200 || d.UnknownS != 0 || d.State != uptimeStateUp {
		t.Fatalf("today = %+v, want up/43200/0 unknown", d)
	}
	wantPct(t, d.UptimePct, 100, "api today")
}

// dayVerdict is the one place seconds become a state: the thresholds pinned.
func TestDayVerdictThresholds(t *testing.T) {
	cases := []struct {
		up, down int64
		state    string
		pct      *float64
	}{
		{0, 0, uptimeStateNoData, nil},
		{100, 0, uptimeStateUp, ptrF(100)},
		{0, 100, uptimeStateDown, ptrF(0)},
		{9950, 50, uptimeStateDegraded, ptrF(99.5)}, // >= floor
		{9800, 200, uptimeStateDown, ptrF(98)},      // < floor
	}
	for _, c := range cases {
		state, pct := dayVerdict(c.up, c.down)
		if state != c.state {
			t.Fatalf("dayVerdict(%d,%d) state = %s, want %s", c.up, c.down, state, c.state)
		}
		if (pct == nil) != (c.pct == nil) || (pct != nil && *pct != *c.pct) {
			t.Fatalf("dayVerdict(%d,%d) pct = %v, want %v", c.up, c.down, pct, c.pct)
		}
	}
}

func ptrF(v float64) *float64 { return &v }

// The status pill reads the freshest tick — up/down when fresh, no_data when
// the newest sample is stale (sampler not running) or when only gaps exist.
func TestCurrentStatus(t *testing.T) {
	now := uptimeDay0.Add(12 * time.Hour)
	stale := 15 * time.Minute

	fresh := []store.HealthSamplesSinceRow{
		tickAt(now.Add(-10*time.Minute), now.Add(-5*time.Minute), false, true, true),
	}
	if s := currentStatus(fresh, uptimeCompAPI, now, stale); s != uptimeStateDown {
		t.Fatalf("fresh !db_ok api status = %s, want down", s)
	}
	if s := currentStatus(fresh, uptimeCompBackups, now, stale); s != uptimeStateUp {
		t.Fatalf("fresh backups status = %s, want up", s)
	}

	old := []store.HealthSamplesSinceRow{
		tickAt(now.Add(-2*time.Hour), now.Add(-time.Hour), true, true, true),
	}
	if s := currentStatus(old, uptimeCompAPI, now, stale); s != uptimeStateNoData {
		t.Fatalf("stale tick status = %s, want no_data", s)
	}

	gapOnly := []store.HealthSamplesSinceRow{
		gapAt(now.Add(-10*time.Minute), now.Add(-5*time.Minute), healthGapDeploy),
	}
	if s := currentStatus(gapOnly, uptimeCompAPI, now, stale); s != uptimeStateNoData {
		t.Fatalf("gap-only status = %s, want no_data", s)
	}
	if s := currentStatus(nil, uptimeCompAPI, now, stale); s != uptimeStateNoData {
		t.Fatalf("empty status = %s, want no_data", s)
	}
}

// Endpoint test: auth path (401/403/200) + wire shape over seeded samples.
func TestOpsUptimeEndpoint(t *testing.T) {
	resetDB(t)
	admin, adminToken := createTestUser(t, "uptime-admin@example.com")
	makeAdmin(t, admin.ID)
	_, userToken := createTestUser(t, "uptime-user@example.com")

	if rec := doJSON(t, "GET", "/api/v1/admin/ops/uptime", userToken, nil); rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin = %d, want 403", rec.Code)
	}
	if rec := doJSON(t, "GET", "/api/v1/admin/ops/uptime", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous = %d, want 401", rec.Code)
	}

	// Seed: two hours of today observed green except stale backups.
	now := time.Now().UTC()
	q := store.New(dbPool)
	dbOK, aiOK, backupsOK := true, true, false
	if err := q.InsertHealthSample(context.Background(), store.InsertHealthSampleParams{
		ObservedAt: now.Add(-time.Minute),
		CoversFrom: now.Add(-time.Minute).Add(-2 * time.Hour),
		Kind:       healthSampleTick,
		DbOk:       &dbOK, AiOk: &aiOK, BackupsOk: &backupsOK,
	}); err != nil {
		t.Fatalf("seed sample: %v", err)
	}

	rec := doJSON(t, "GET", "/api/v1/admin/ops/uptime?days=90", adminToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("admin = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if got := body["days"].(float64); got != 90 {
		t.Fatalf("days = %v, want 90", got)
	}
	if _, ok := body["monitoring_since"].(string); !ok {
		t.Fatalf("monitoring_since missing/not a string: %v", body["monitoring_since"])
	}
	comps, _ := body["components"].([]any)
	if len(comps) != uptimeCompCount {
		t.Fatalf("components = %d, want %d", len(comps), uptimeCompCount)
	}
	byKey := map[string]map[string]any{}
	for _, ci := range comps {
		c := ci.(map[string]any)
		byKey[c["key"].(string)] = c
		if days, _ := c["days"].([]any); len(days) != 90 {
			t.Fatalf("%s: days = %d, want dense 90", c["key"], len(days))
		}
	}
	lastDay := func(key string) map[string]any {
		days := byKey[key]["days"].([]any)
		return days[len(days)-1].(map[string]any)
	}
	// The seeded observation lands on today (UTC): api green, backups down.
	if d := lastDay("api"); d["state"] != uptimeStateUp || d["uptime_pct"].(float64) != 100 {
		t.Fatalf("api today = %v", d)
	}
	if d := lastDay("backups"); d["state"] != uptimeStateDown {
		t.Fatalf("backups today = %v", d)
	} else if codes, _ := d["reason_codes"].([]any); len(codes) != 1 || codes[0] != uptimeReasonBackupsStale {
		t.Fatalf("backups today reasons = %v", d["reason_codes"])
	}
	// A pre-monitoring day is no_data with a NULL pct — never 0 or 100.
	if d := byKey["api"]["days"].([]any)[0].(map[string]any); d["state"] != uptimeStateNoData || d["uptime_pct"] != nil {
		t.Fatalf("api day0 = %v, want no_data/null", d)
	}
	// Pills: api fresh-and-ok, backups fresh-and-stale.
	if byKey["api"]["status"] != uptimeStateUp || byKey["backups"]["status"] != uptimeStateDown {
		t.Fatalf("statuses = api:%v backups:%v", byKey["api"]["status"], byKey["backups"]["status"])
	}
}
