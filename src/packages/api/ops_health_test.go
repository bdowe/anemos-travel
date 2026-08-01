package main

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// --- providerStatuses across env combinations ---

func TestProviderStatuses(t *testing.T) {
	// The three token-emptiness providers we can toggle via env (the others
	// read singletons/globals fixed at package init). Setting them proves the
	// consolidated list reflects configuration; clearing proves the inverse.
	t.Setenv("GOOGLE_PLACES_API_KEY", "pk")
	t.Setenv("ANTHROPIC_API_KEY", "")
	t.Setenv("TICKETMASTER_API_KEY", "tm")

	byName := map[string]ProviderStat{}
	for _, p := range providerStatuses() {
		byName[p.Name] = p
	}

	// All eight expected providers are present.
	for _, name := range []string{
		"google_places", "anthropic", "duffel", "ticketmaster",
		"email", "google_oauth", "transcription", "sentry",
	} {
		if _, ok := byName[name]; !ok {
			t.Fatalf("provider %q missing from statuses", name)
		}
	}

	if !byName["google_places"].Configured {
		t.Errorf("google_places should be configured (env set)")
	}
	if byName["anthropic"].Configured {
		t.Errorf("anthropic should be unconfigured (env empty)")
	}
	if !byName["ticketmaster"].Configured {
		t.Errorf("ticketmaster should be configured (env set)")
	}

	// Note is consistent with Configured for every entry.
	for _, p := range providerStatuses() {
		if p.Configured && p.Note != "" {
			t.Errorf("%s configured but has note %q", p.Name, p.Note)
		}
		if !p.Configured && p.Note != "not configured" {
			t.Errorf("%s unconfigured but note = %q", p.Name, p.Note)
		}
	}
}

func TestProviderStatusesUnsetClears(t *testing.T) {
	t.Setenv("GOOGLE_PLACES_API_KEY", "")
	t.Setenv("TICKETMASTER_API_KEY", "")
	byName := map[string]ProviderStat{}
	for _, p := range providerStatuses() {
		byName[p.Name] = p
	}
	if byName["google_places"].Configured || byName["ticketmaster"].Configured {
		t.Fatalf("cleared providers still report configured")
	}
}

// --- evalBackupHealth: fresh / stale / missing ---

func TestEvalBackupHealth(t *testing.T) {
	now := time.Date(2026, 7, 19, 12, 0, 0, 0, time.UTC)

	// Fresh: 1 hour old, 36h threshold => not stale, fields populated.
	fresh := now.Add(-1 * time.Hour).Format(time.RFC3339)
	b := evalBackupHealth(now, fresh+"\n", nil, 36)
	if b.Stale {
		t.Errorf("fresh backup marked stale")
	}
	if b.LastSuccessAt == nil || b.AgeS == nil {
		t.Fatalf("fresh backup missing fields: %+v", b)
	}
	if *b.AgeS != 3600 {
		t.Errorf("age_s = %d, want 3600", *b.AgeS)
	}

	// Stale: 40 hours old, 36h threshold => stale.
	old := now.Add(-40 * time.Hour).Format(time.RFC3339)
	b = evalBackupHealth(now, old, nil, 36)
	if !b.Stale {
		t.Errorf("40h-old backup not marked stale")
	}
	if b.LastSuccessAt == nil {
		t.Errorf("stale-but-present backup should still expose timestamp")
	}

	// Missing file (read error): stale, no fields.
	b = evalBackupHealth(now, "", errors.New("no such file"), 36)
	if !b.Stale || b.LastSuccessAt != nil || b.AgeS != nil {
		t.Errorf("missing heartbeat should be stale/null: %+v", b)
	}

	// Unparseable contents: treated like missing.
	b = evalBackupHealth(now, "garbage", nil, 36)
	if !b.Stale || b.LastSuccessAt != nil {
		t.Errorf("unparseable heartbeat should be stale/null: %+v", b)
	}
}

// --- computeHealthState transition matrix ---

func TestComputeHealthState(t *testing.T) {
	failing := aiHealthState{Failing: true, Reason: "credit balance"}
	cases := []struct {
		dbOK, backupsStale bool
		ai                 aiHealthState
		wantDegraded       bool
		wantReasons        []string
	}{
		{true, false, aiHealthState{}, false, []string{}},
		{false, false, aiHealthState{}, true, []string{"database unreachable"}},
		{true, true, aiHealthState{}, true, []string{"backups stale"}},
		{false, true, aiHealthState{}, true, []string{"database unreachable", "backups stale"}},
		{true, false, failing, true, []string{"AI provider failing: credit balance"}},
		{false, true, failing, true, []string{"database unreachable", "backups stale", "AI provider failing: credit balance"}},
		// Defensive: Failing with no reason still yields a readable line.
		{true, false, aiHealthState{Failing: true}, true, []string{"AI provider failing: unknown"}},
		// A non-failing tracker with history is not degraded.
		{true, false, aiHealthState{Reason: "credit balance", FatalTotal: 3}, false, []string{}},
	}
	for _, c := range cases {
		got := computeHealthState(c.dbOK, c.backupsStale, c.ai)
		if got.degraded != c.wantDegraded {
			t.Errorf("dbOK=%v stale=%v ai=%+v: degraded=%v want %v", c.dbOK, c.backupsStale, c.ai, got.degraded, c.wantDegraded)
		}
		if got.reasons == nil {
			t.Errorf("reasons must be non-nil")
		}
		if strings.Join(got.reasons, "|") != strings.Join(c.wantReasons, "|") {
			t.Errorf("dbOK=%v stale=%v ai=%+v: reasons=%v want %v", c.dbOK, c.backupsStale, c.ai, got.reasons, c.wantReasons)
		}
	}
}

// --- buildOpsAlertEmail content ---

func TestBuildOpsAlertEmail(t *testing.T) {
	appURL := "https://app.example.com/"

	subject, body := buildOpsAlertEmail(true, []string{"database unreachable", "backups stale"}, appURL)
	if !strings.Contains(subject, "degraded") {
		t.Errorf("degrade subject = %q", subject)
	}
	for _, want := range []string{"database unreachable", "backups stale", appURL} {
		if !strings.Contains(body, want) {
			t.Errorf("degrade body missing %q:\n%s", want, body)
		}
	}

	subject, body = buildOpsAlertEmail(false, nil, appURL)
	if !strings.Contains(subject, "recovered") {
		t.Errorf("recover subject = %q", subject)
	}
	if !strings.Contains(body, "recovered") || !strings.Contains(body, appURL) {
		t.Errorf("recover body:\n%s", body)
	}
}

// --- opsHealthHandler shape ---

// writeFreshHeartbeat points BACKUP_HEARTBEAT_FILE at a temp file holding a
// just-now timestamp so backups are not stale (isolating the DB signal).
func writeFreshHeartbeat(t *testing.T, now time.Time) {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".last_success")
	if err := os.WriteFile(path, []byte(now.Format(time.RFC3339)+"\n"), 0o600); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}
	t.Setenv("BACKUP_HEARTBEAT_FILE", path)
}

func TestOpsHealthHandlerNoDB(t *testing.T) {
	saved := dbPool
	dbPool = nil
	defer func() { dbPool = saved }()

	req := httptest.NewRequest("GET", "/api/v1/admin/ops/health", nil)
	rec := httptest.NewRecorder()
	opsHealthHandler(rec, req)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (renders even with no DB)", rec.Code)
	}
	var got DependencyHealth
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("bad JSON: %v", err)
	}
	if got.DB.Status != "not_configured" {
		t.Errorf("db.status = %q, want not_configured", got.DB.Status)
	}
	if !got.Degraded {
		t.Errorf("no DB should be degraded")
	}
	if got.Reasons == nil {
		t.Errorf("reasons must be non-nil (empty slice, not null)")
	}
	if len(got.Providers) != 8 {
		t.Errorf("providers len = %d, want 8", len(got.Providers))
	}
	if got.Build.GoVersion == "" || got.Build.StartedAt == "" {
		t.Errorf("build info incomplete: %+v", got.Build)
	}
}

func TestOpsHealthHandlerDBUp(t *testing.T) {
	requireDB(t)
	writeFreshHeartbeat(t, time.Now())
	// Defensive: this test asserts not-degraded through the global aiHealth
	// tracker — don't let a fatal-writing test that forgot its cleanup poison
	// the ordering.
	resetAIHealth(t)

	req := httptest.NewRequest("GET", "/api/v1/admin/ops/health", nil)
	rec := httptest.NewRecorder()
	opsHealthHandler(rec, req)

	var got DependencyHealth
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("bad JSON: %v", err)
	}
	if got.DB.Status != "ok" {
		t.Fatalf("db.status = %q, want ok", got.DB.Status)
	}
	if got.Degraded {
		t.Errorf("DB up + fresh backup should not be degraded: reasons=%v", got.Reasons)
	}
	if got.Reasons == nil || len(got.Reasons) != 0 {
		t.Errorf("healthy reasons should be empty non-nil, got %v", got.Reasons)
	}
}
