package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"math/rand"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Health self-check monitor (Observability PR2): a background ticker that
// re-evaluates the same deterministic health signals the /admin/ops/health
// endpoint reports (DB reachability, backup freshness, AI-provider health) and
// alerts on TRANSITIONS only — any change to the REASON SET, not just the
// healthy<->degraded boolean, so a second outage arriving while already
// degraded (backups stale, then the AI account runs dry) still alerts instead
// of hiding behind the first. It mirrors the price-alert / re-engagement
// checker shape exactly (own goroutine, env-cadence ticker, jittered first
// tick, dbPool-nil guard, injectable clock in runOnce).
//
// Alerting on transitions (not on every degraded tick) is the dedup: a five-
// minute tick over a multi-hour outage fires ONE alert, and one recovery. State
// lives in memory on the checker, so a restart while still degraded re-alerts
// once — acceptable (Brian) and not worth a table.
//
// Three channels fire on a transition:
//   - slog.Error on degrade (teed to Sentry via sentry_slog.go); slog.Info on
//     recovery.
//   - an in-app notification per admin user (ops_alert / ops_recovered).
//   - an email per admin, but ONLY when SMTP is configured.
//
// This monitor never pings paid providers — the AI-provider signal is read
// from process memory (ai_health.go, recorded passively by the real AI call
// sites), so the loop costs one cheap DB ping and one file stat per tick.

const (
	defaultHealthTickMinutes = 5

	notificationTypeOpsAlert     = "ops_alert"
	notificationTypeOpsRecovered = "ops_recovered"
)

type healthMonitor struct {
	interval time.Duration
	// lastReasons is the in-memory transition state: the previous tick's
	// reason set, joined. Starts "" (healthy). Keying the dedup on the SET
	// rather than a degraded boolean means an outage that begins while
	// another is ongoing still fires its own alert.
	lastReasons string

	// Injectable seams for tests. Defaulted in startHealthMonitor to the real
	// store/email singletons.
	listAdmins   func(context.Context) ([]store.ListAdminUsersRow, error)
	insertNotify func(context.Context, store.InsertNotificationParams) error
	sendEmail    func(to, subject, body string) error
	emailEnabled func() bool
	pingDBFn     func(context.Context) bool
	aiStateFn    func() aiHealthState
}

// startHealthMonitor launches the background loop. No-ops (with a log line)
// when persistence is unavailable — with no DB there is no admin list to alert
// and pingDB is always false; the monitor resumes on next boot once a database
// is configured, exactly like startAlertChecker.
func startHealthMonitor(ctx context.Context) {
	if dbPool == nil {
		log.Printf("ops health: monitor disabled (no database)")
		return
	}
	m := &healthMonitor{
		interval: time.Duration(envInt("HEALTH_TICK_MINUTES", defaultHealthTickMinutes)) * time.Minute,
		listAdmins: func(ctx context.Context) ([]store.ListAdminUsersRow, error) {
			return store.New(dbPool).ListAdminUsers(ctx)
		},
		insertNotify: func(ctx context.Context, p store.InsertNotificationParams) error {
			_, err := store.New(dbPool).InsertNotification(ctx, p)
			return err
		},
		sendEmail:    func(to, subject, body string) error { return emailService.Send(to, subject, body) },
		emailEnabled: func() bool { return emailService.Configured() },
		pingDBFn:     pingDB,
		// Same source the /admin/ops/health endpoint reads, so the endpoint
		// and the alert loop can never disagree about the AI signal.
		aiStateFn: aiHealth.state,
	}
	go m.run(ctx)
	log.Printf("ops health: monitor started (tick %s)", m.interval)
}

func (m *healthMonitor) run(ctx context.Context) {
	// Jitter the first tick so restarts don't synchronize a burst of alerts.
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Duration(rand.Int63n(int64(m.interval)))):
	}
	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()
	for {
		// Guard each tick: a panic in one cycle must not kill the ticker (and
		// with it the whole process). Log-and-continue to the next tick.
		safeRun("health monitor tick", func() { m.runOnce(ctx, time.Now()) })
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// runOnce evaluates health once and alerts on a transition. now is the testable
// clock (drives backup-freshness). On no change to the reason set it does
// nothing — that is the dedup that keeps a long outage to a single alert. A
// reason-set change while still degraded (a second outage joining, or one of
// two clearing) fires a fresh degraded alert carrying the CURRENT reasons.
func (m *healthMonitor) runOnce(ctx context.Context, now time.Time) {
	dbOK := m.pingDBFn(ctx)
	backups := readBackupHealth(now)
	state := computeHealthState(dbOK, backups.Stale, m.aiStateFn())

	reasonsKey := strings.Join(state.reasons, "|")
	if reasonsKey == m.lastReasons {
		return // no transition — the dedup
	}
	m.lastReasons = reasonsKey
	m.alertTransition(ctx, state)
}

// alertTransition fires all three channels for one healthy<->degraded flip.
func (m *healthMonitor) alertTransition(ctx context.Context, state healthState) {
	if state.degraded {
		// LevelError is teed to Sentry (sentry_slog.go).
		slog.Error("ops health degraded", "reasons", strings.Join(state.reasons, ", "))
	} else {
		slog.Info("ops health recovered")
	}

	admins, err := m.listAdmins(ctx)
	if err != nil {
		log.Printf("ops health: list admins failed: %v", err)
		return
	}

	notifType := notificationTypeOpsRecovered
	if state.degraded {
		notifType = notificationTypeOpsAlert
	}
	payload := opsAlertPayload(state)

	for _, a := range admins {
		if err := m.insertNotify(ctx, store.InsertNotificationParams{
			UserID:  a.ID,
			Type:    notifType,
			Payload: payload,
			TripID:  pgtype.UUID{}, // no trip association
		}); err != nil {
			log.Printf("ops health: insert %s notification for %s failed: %v", notifType, a.ID, err)
		}
	}

	// Email is the only gated channel: skip entirely when SMTP is unconfigured.
	if !m.emailEnabled() {
		return
	}
	subject, body := buildOpsAlertEmail(state.degraded, state.reasons, publicAppURL())
	for _, a := range admins {
		if err := m.sendEmail(a.Email, subject, body); err != nil {
			log.Printf("ops health: alert email to %s failed: %v", maskEmail(a.Email), err)
		}
	}
}

// opsAlertPayload is the self-describing render bag for the in-app ops
// notification, the same convention as the other notification payloads.
func opsAlertPayload(state healthState) []byte {
	b, err := json.Marshal(map[string]any{
		"degraded": state.degraded,
		"reasons":  state.reasons,
	})
	if err != nil {
		return []byte(`{}`)
	}
	return b
}

// buildOpsAlertEmail renders the operator alert email. Pure — unit-tested. On
// degrade it lists the reasons; on recovery it confirms all-clear. appURL links
// back to the app (the ops dashboard lives behind it).
func buildOpsAlertEmail(degraded bool, reasons []string, appURL string) (subject, body string) {
	var b strings.Builder
	if degraded {
		subject = "[ops] Golden Tempo API degraded"
		b.WriteString("The Golden Tempo API self-check detected a degradation.\n\n")
		b.WriteString("Reasons:\n")
		if len(reasons) == 0 {
			b.WriteString("  - (unspecified)\n")
		}
		for _, r := range reasons {
			fmt.Fprintf(&b, "  - %s\n", r)
		}
	} else {
		subject = "[ops] Golden Tempo API recovered"
		b.WriteString("The Golden Tempo API self-check reports all clear — health has recovered.\n")
	}
	fmt.Fprintf(&b, "\nOps dashboard: %s\n", appURL)
	return subject, b.String()
}
