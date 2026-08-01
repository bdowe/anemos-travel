package main

import (
	"context"
	"net/http"
	"os"
	"runtime"
	"strings"
	"time"
)

// Consolidated dependency-health endpoint (Observability PR2): GET
// /api/v1/admin/ops/health rolls up the DB, every provider's "configured"
// state, build/runtime info, and backup freshness into one DependencyHealth
// document, plus a top-level Degraded verdict + Reasons list.
//
// Like opsMetricsHandler this has NO dbPool guard: the endpoint must render
// even when the database is down — that is exactly when an operator needs it.
// The DB section reports "unreachable"/"not_configured" instead of failing the
// request. Admin auth is still enforced at route registration.
//
// The pure helpers (providerStatuses, evalBackupHealth, computeHealthState) are
// shared verbatim with the self-check monitor (ops_monitor.go) so the endpoint
// and the alert loop can never disagree about what "degraded" means.

const (
	defaultBackupHeartbeatFile = "/opt/goldentempo/backups/.last_success"
	defaultBackupStaleHours    = 36
)

// DependencyHealth is the wire contract of GET /admin/ops/health. Field tags
// are load-bearing: PR3 (Flutter ops dashboard) builds against this exact shape.
type DependencyHealth struct {
	DB        HealthDB       `json:"db"`
	Providers []ProviderStat `json:"providers"`
	Build     BuildInfo      `json:"build"`
	Backups   BackupInfo     `json:"backups"`
	Degraded  bool           `json:"degraded"`
	Reasons   []string       `json:"reasons"` // non-nil (empty slice, not null)
}

// HealthDB reports database reachability. Status is one of "ok",
// "unreachable", or "not_configured"; PingMs is the ping round-trip in ms
// (0 when not ok).
type HealthDB struct {
	Status string `json:"status"`
	PingMs int    `json:"ping_ms"`
}

// ProviderStat is one external dependency's configuration status. Configured
// reflects whether the credential/config needed to use it is present; Note is
// an optional human hint (e.g. "not configured").
type ProviderStat struct {
	Name       string `json:"name"`
	Configured bool   `json:"configured"`
	Note       string `json:"note"`
}

// BuildInfo is static build/runtime provenance for the running process.
type BuildInfo struct {
	Release   string `json:"release"`
	GoVersion string `json:"go_version"`
	StartedAt string `json:"started_at"` // ISO8601 (RFC3339)
	UptimeS   int64  `json:"uptime_s"`
}

// BackupInfo is the freshness of the last successful DB backup, read from the
// heartbeat file the backup job writes. LastSuccessAt/AgeS are nil when no
// heartbeat exists; Stale is true then too.
type BackupInfo struct {
	LastSuccessAt *string `json:"last_success_at"` // ISO8601, null if none
	AgeS          *int64  `json:"age_s"`           // null if none
	Stale         bool    `json:"stale"`
}

// opsHealthHandler serves GET /api/v1/admin/ops/health.
func opsHealthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, buildDependencyHealth(r.Context(), time.Now()))
}

// buildDependencyHealth assembles the full document. now is injectable so the
// backup-freshness math is testable.
func buildDependencyHealth(ctx context.Context, now time.Time) DependencyHealth {
	db := probeDB(ctx)
	backups := readBackupHealth(now)
	state := computeHealthState(db.Status == "ok", backups.Stale, aiHealth.state())
	return DependencyHealth{
		DB:        db,
		Providers: providerStatuses(),
		Build:     buildInfo(now),
		Backups:   backups,
		Degraded:  state.degraded,
		Reasons:   state.reasons,
	}
}

// probeDB pings the database and reports status + latency. "not_configured"
// when there is no pool, "unreachable" when a ping fails, "ok" otherwise.
func probeDB(ctx context.Context) HealthDB {
	if dbPool == nil {
		return HealthDB{Status: "not_configured"}
	}
	start := time.Now()
	if !pingDB(ctx) {
		return HealthDB{Status: "unreachable"}
	}
	return HealthDB{Status: "ok", PingMs: int(time.Since(start).Milliseconds())}
}

// buildInfo captures static build/runtime provenance.
func buildInfo(now time.Time) BuildInfo {
	return BuildInfo{
		Release:   os.Getenv("SENTRY_RELEASE"),
		GoVersion: runtime.Version(),
		StartedAt: processStart.UTC().Format(time.RFC3339),
		UptimeS:   int64(now.Sub(processStart).Seconds()),
	}
}

// providerStatuses is the consolidated external-dependency configuration list.
// Each entry's Configured flag reuses that provider's own "configured" check so
// this stays the single source of truth for provider readiness. Order is
// stable for a deterministic UI.
func providerStatuses() []ProviderStat {
	stat := func(name string, ok bool) ProviderStat {
		note := ""
		if !ok {
			note = "not configured"
		}
		return ProviderStat{Name: name, Configured: ok, Note: note}
	}

	duffelConfigured := duffelService != nil && duffelService.Token != ""
	emailConfigured := emailService != nil && emailService.Configured()
	transcriptionConfigured := transcriptionService != nil && transcriptionService.Configured()

	// The duffel row stays truthful while the temporary offers swap is active
	// (airports/IATA resolution still ride Duffel); the serpapi_flights row
	// carries the swap state so the ops view can't miss it.
	serpapiStat := stat("serpapi_flights", serpapiFlights.Configured())
	switch {
	case serpapiFlights.Active() && serpapiFlights.Configured():
		serpapiStat.Note = "temporary flight-offers provider ACTIVE; price alerts paused"
	case serpapiFlights.Active():
		serpapiStat.Note = "ACTIVE but key missing; flight search degrades to Google Flights links"
	}

	return []ProviderStat{
		stat("google_places", os.Getenv("GOOGLE_PLACES_API_KEY") != ""),
		stat("anthropic", os.Getenv("ANTHROPIC_API_KEY") != ""),
		stat("duffel", duffelConfigured),
		serpapiStat,
		stat("ticketmaster", os.Getenv("TICKETMASTER_API_KEY") != ""),
		stat("email", emailConfigured),
		stat("google_oauth", googleOAuthConfigured()),
		stat("transcription", transcriptionConfigured),
		stat("sentry", sentryEnabled),
	}
}

// readBackupHealth reads the backup heartbeat file and evaluates its freshness
// against BACKUP_STALE_HOURS. The file (written by backup.sh) holds a single
// RFC3339 timestamp from `date -u +%FT%TZ`.
func readBackupHealth(now time.Time) BackupInfo {
	path := os.Getenv("BACKUP_HEARTBEAT_FILE")
	if path == "" {
		path = defaultBackupHeartbeatFile
	}
	contents, err := os.ReadFile(path)
	return evalBackupHealth(now, string(contents), err, envInt("BACKUP_STALE_HOURS", defaultBackupStaleHours))
}

// evalBackupHealth is the pure freshness evaluator. A missing/unreadable/
// unparseable heartbeat yields last_success_at=null, age_s=null, stale=true (no
// evidence of a recent backup is itself a degraded signal). Otherwise Stale is
// true once the heartbeat is older than staleHours.
func evalBackupHealth(now time.Time, contents string, readErr error, staleHours int) BackupInfo {
	if readErr != nil {
		return BackupInfo{Stale: true}
	}
	ts, perr := time.Parse(time.RFC3339, strings.TrimSpace(contents))
	if perr != nil {
		return BackupInfo{Stale: true}
	}
	iso := ts.UTC().Format(time.RFC3339)
	ageS := int64(now.Sub(ts).Seconds())
	if ageS < 0 {
		ageS = 0
	}
	stale := now.Sub(ts) > time.Duration(staleHours)*time.Hour
	return BackupInfo{LastSuccessAt: &iso, AgeS: &ageS, Stale: stale}
}

// healthState is the deterministic degraded verdict shared by the endpoint and
// the monitor.
type healthState struct {
	degraded bool
	reasons  []string
}

// computeHealthState derives the top-level degraded verdict from three
// deterministic, unpriced signals: DB reachability, backup freshness, and the
// AI provider's passively-tracked health (ai_health.go — fatal billing/auth
// failures recorded by the real AI call sites; no probe is ever sent). It
// deliberately does NOT consider provider configuration (a missing optional
// provider key is not "the service is unhealthy") and never pings paid
// providers. Once fatal, the AI signal clears only on the next successful AI
// call — with zero AI traffic the state stays degraded, which is correct for
// billing/auth outages (they don't fix themselves). reasons is always non-nil.
func computeHealthState(dbOK, backupsStale bool, ai aiHealthState) healthState {
	reasons := []string{}
	if !dbOK {
		reasons = append(reasons, "database unreachable")
	}
	if backupsStale {
		reasons = append(reasons, "backups stale")
	}
	if ai.Failing {
		reason := ai.Reason
		if reason == "" {
			reason = "unknown"
		}
		reasons = append(reasons, "AI provider failing: "+reason)
	}
	return healthState{degraded: len(reasons) > 0, reasons: reasons}
}
