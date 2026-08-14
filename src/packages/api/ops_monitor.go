package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"math/rand"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Health self-check monitor (Observability PR2): a background ticker that
// re-evaluates the same deterministic health signals the /admin/ops/health
// endpoint reports (DB reachability, backup freshness, AI-provider health) and
// alerts on TRANSITIONS only — any change to the REASON SET, not just the
// healthy<->degraded boolean, so a second outage arriving while already
// degraded (backups stale, then the AI account runs dry) still alerts instead
// of hiding behind the first. It mirrors the re-engagement checker shape
// exactly (own goroutine, env-cadence ticker, jittered first tick,
// dbPool-nil guard, injectable clock in runOnce).
//
// Alerting on transitions (not on every degraded tick) is the dedup: a five-
// minute tick over a multi-hour outage fires ONE alert, and one recovery. State
// lives in memory on the checker, so a restart while still degraded re-alerts
// once — acceptable (Brian) and not worth a table.
//
// The tick ALSO persists what it saw, one row per tick, for the Health pane's
// 90-day uptime strip (specs/uptime-history, rollup in ops_uptime.go). That is
// history, not alerting: it is written every tick, before the transition dedup
// returns, and a write failure never touches the alert path. The "not worth a
// table" call above still stands for the alerting dedup — a graph is what
// needed one.
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

	// Uptime-history sample kinds and gap causes (health_samples.kind /
	// .gap_cause, migration 00059). Mirrored by the rollup in ops_uptime.go.
	healthSampleTick = "tick"
	healthSampleGap  = "gap"
	// healthGapDeploy is a gap explained by a release change: the container was
	// replaced. Unobserved time, charged to nobody — 6-12 deploys/day would
	// otherwise invent ~4%/day of downtime out of nothing.
	healthGapDeploy = "deploy"
	// healthGapUnknown is a gap on the SAME release: a crash, an OOM kill, a
	// host reboot. Charged as downtime — it is the only thing that can redden a
	// bar without a health signal itself having failed.
	healthGapUnknown = "unknown"

	// healthSampleBufferMax bounds the retry buffer at one day of ticks at the
	// default cadence. Past that the oldest held sample is dropped.
	healthSampleBufferMax = 288

	// healthSampleTimeout bounds one sample write so a wedged database cannot
	// pin a tick; the next tick retries from the buffer anyway.
	healthSampleTimeout = 10 * time.Second
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

	// Uptime-history persistence (specs/uptime-history). Its OWN seam, separate
	// from the alerting ones, so a test can fail sample writes without
	// perturbing the transition alerts (and vice versa).
	insertSample func(context.Context, store.InsertHealthSampleParams) error

	// release is SENTRY_RELEASE at boot, stamped onto every sample; the boot
	// gap's cause is decided by comparing it against the previous row's.
	release string

	// lastSampleAt is the end of the last interval this process accounted for
	// (sample written OR buffered — it advances either way, so a failed write
	// never double-counts its interval on the next tick). Set by
	// bootstrapSamples, read/written only on the ticker goroutine.
	lastSampleAt time.Time

	// sampleMu guards pending: the retry buffer holding samples whose write
	// failed. The buffer is the reason a DATABASE outage is visible in its own
	// history at all — a tick that observes db_ok=false cannot write that
	// observation because the database is what's down, so it is held (with its
	// real timestamps, delayed writes of real observations, never back-dated
	// inventions) and flushed on the next successful write. A crash while
	// holding loses them; that time then reads as a gap → downtime, which is
	// conservative in the right direction. Bounded at healthSampleBufferMax.
	sampleMu sync.Mutex
	pending  []store.InsertHealthSampleParams
}

// startHealthMonitor launches the background loop. No-ops (with a log line)
// when persistence is unavailable — with no DB there is no admin list to alert
// and pingDB is always false; the monitor resumes on next boot once a database
// is configured, exactly like startReengagementChecker.
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
		insertSample: func(ctx context.Context, p store.InsertHealthSampleParams) error {
			return store.New(dbPool).InsertHealthSample(ctx, p)
		},
		release: os.Getenv("SENTRY_RELEASE"),
	}
	// Close the previous process's gap BEFORE the loop starts: every
	// millisecond boot is delayed is a millisecond the gap row grows by.
	m.bootstrapSamples(ctx, time.Now(), func(ctx context.Context) (store.LastHealthSampleRow, error) {
		return store.New(dbPool).LastHealthSample(ctx)
	})
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
	ai := m.aiStateFn()
	state := computeHealthState(dbOK, backups.Stale, ai)

	// Persist the observation BEFORE the transition dedup returns: history
	// records every tick, alerting only changes (specs/uptime-history). Same
	// signal reads as the alert verdict, so the row and the alert can never
	// disagree about one tick.
	m.recordTick(ctx, now, dbOK, !backups.Stale, !ai.Failing)

	reasonsKey := strings.Join(state.reasons, "|")
	if reasonsKey == m.lastReasons {
		return // no transition — the dedup
	}
	m.lastReasons = reasonsKey
	m.alertTransition(ctx, state)
}

// --- Uptime-history sampling (specs/uptime-history) --------------------------

// bootstrapSamples writes the boot gap row: the span between the previous
// process's last observation and now, which nobody observed. Its cause is
// decided by the release comparison — changed release = the container was
// replaced (a deploy; unobserved time, charged to nobody), same release = a
// crash/OOM/host reboot (downtime). An empty table means monitoring simply
// starts now; a failed read is logged and skipped (worst case the gap merges
// into the next boot's, same span, same verdict). lastSampleAt starts at now
// either way, so the first tick covers [boot, first tick] — time this process
// was verifiably alive.
func (m *healthMonitor) bootstrapSamples(ctx context.Context, now time.Time, lastSample func(context.Context) (store.LastHealthSampleRow, error)) {
	m.lastSampleAt = now
	last, err := lastSample(ctx)
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			slog.Warn("ops health: read last sample failed; boot gap not recorded", "error", err)
		}
		return
	}
	if !last.ObservedAt.Before(now) {
		return // clock skew backwards; refuse to write a negative interval
	}
	cause := healthGapUnknown
	if last.Release != m.release {
		cause = healthGapDeploy
	}
	m.writeSample(ctx, store.InsertHealthSampleParams{
		ObservedAt: now,
		CoversFrom: last.ObservedAt,
		Kind:       healthSampleGap,
		Release:    m.release,
		GapCause:   &cause,
	})
}

// recordTick persists one tick's verdict as the interval [lastSampleAt, now].
// If the sampler itself stalled (paused VM, wedged goroutine — the gap exceeds
// 2× the cadence), only the last interval is vouched for; the excess becomes
// an explicit unknown-gap row first, so a stall can never silently claim hours
// of health it did not observe.
func (m *healthMonitor) recordTick(ctx context.Context, now time.Time, dbOK, backupsOK, aiOK bool) {
	// Sampling disabled (no seam wired — alerting-focused tests) or not yet
	// anchored (bootstrapSamples not run): advance the anchor only, so a later
	// tick can never claim time nobody observed.
	if m.insertSample == nil || m.lastSampleAt.IsZero() {
		m.lastSampleAt = now
		return
	}
	from := m.lastSampleAt
	if !from.Before(now) {
		return // clock skew backwards; skip rather than write a negative interval
	}
	if stallLimit := 2 * m.interval; now.Sub(from) > stallLimit {
		cause := healthGapUnknown
		gapEnd := now.Add(-m.interval)
		m.writeSample(ctx, store.InsertHealthSampleParams{
			ObservedAt: gapEnd,
			CoversFrom: from,
			Kind:       healthSampleGap,
			Release:    m.release,
			GapCause:   &cause,
		})
		from = gapEnd
	}
	m.lastSampleAt = now
	m.writeSample(ctx, store.InsertHealthSampleParams{
		ObservedAt: now,
		CoversFrom: from,
		Kind:       healthSampleTick,
		Release:    m.release,
		DbOk:       &dbOK,
		AiOk:       &aiOK,
		BackupsOk:  &backupsOK,
	})
}

// writeSample inserts one sample, buffering it on failure and flushing any
// previously buffered samples on success — see the pending field's comment for
// why the buffer exists. Never returns an error: sampling must not perturb the
// alert path.
func (m *healthMonitor) writeSample(ctx context.Context, p store.InsertHealthSampleParams) {
	writeCtx, cancel := context.WithTimeout(ctx, healthSampleTimeout)
	defer cancel()

	if err := m.insertSample(writeCtx, p); err != nil {
		m.sampleMu.Lock()
		m.pending = append(m.pending, p)
		if len(m.pending) > healthSampleBufferMax {
			m.pending = m.pending[len(m.pending)-healthSampleBufferMax:]
			slog.Warn("ops health: sample buffer full; dropped oldest",
				"buffered", len(m.pending))
		}
		m.sampleMu.Unlock()
		slog.Warn("ops health: sample write failed; buffered", "error", err)
		return
	}

	// Success — flush anything held from earlier failures, oldest first,
	// stopping at the first error (the rest stay buffered for next time).
	m.sampleMu.Lock()
	held := m.pending
	m.pending = nil
	m.sampleMu.Unlock()
	for i, hp := range held {
		if err := m.insertSample(writeCtx, hp); err != nil {
			m.sampleMu.Lock()
			m.pending = append(held[i:], m.pending...)
			m.sampleMu.Unlock()
			slog.Warn("ops health: sample flush interrupted", "remaining", len(held)-i, "error", err)
			return
		}
	}
	if len(held) > 0 {
		slog.Info("ops health: flushed buffered samples", "count", len(held))
	}
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
