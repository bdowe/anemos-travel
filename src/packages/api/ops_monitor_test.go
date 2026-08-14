package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

// fakeMailbox records ops-alert emails the monitor would send.
type fakeMailbox struct {
	mu   sync.Mutex
	sent []struct{ to, subject, body string }
}

func (m *fakeMailbox) send(to, subject, body string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent = append(m.sent, struct{ to, subject, body string }{to, subject, body})
	return nil
}

func (m *fakeMailbox) count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.sent)
}

// newTestMonitor wires a monitor to the real store (test DB) with a
// controllable DB-ping, a controllable AI-health state (pointer-flip, like
// the ping), and a fake mailbox.
func newTestMonitor(mailbox *fakeMailbox, emailOn bool, ping *bool, ai *aiHealthState) *healthMonitor {
	return &healthMonitor{
		interval: time.Minute,
		listAdmins: func(ctx context.Context) ([]store.ListAdminUsersRow, error) {
			return store.New(dbPool).ListAdminUsers(ctx)
		},
		insertNotify: func(ctx context.Context, p store.InsertNotificationParams) error {
			_, err := store.New(dbPool).InsertNotification(ctx, p)
			return err
		},
		sendEmail:    mailbox.send,
		emailEnabled: func() bool { return emailOn },
		pingDBFn:     func(context.Context) bool { return *ping },
		aiStateFn:    func() aiHealthState { return *ai },
	}
}

func opsNotifCount(t *testing.T, u uuid.UUID, typ string) int {
	t.Helper()
	rows, err := store.New(dbPool).ListNotificationsByUser(context.Background(),
		store.ListNotificationsByUserParams{UserID: u, Limit: 50})
	if err != nil {
		t.Fatalf("list notifications: %v", err)
	}
	n := 0
	for _, r := range rows {
		if r.Type == typ {
			n++
		}
	}
	return n
}

// A healthy->degraded->healthy sequence fires exactly one alert per transition
// (in-app notification per admin + one email per admin), and a repeat degraded
// tick fires nothing. Only admins are notified.
func TestHealthMonitorTransitions(t *testing.T) {
	requireDB(t)
	resetDB(t)
	writeFreshHeartbeat(t, time.Now()) // isolate the DB signal from backups

	admin1, _ := createTestUser(t, "opsadmin1@example.com")
	admin2, _ := createTestUser(t, "opsadmin2@example.com")
	makeAdmin(t, admin1.ID)
	makeAdmin(t, admin2.ID)
	nonAdmin, _ := createTestUser(t, "regular@example.com")

	mailbox := &fakeMailbox{}
	dbUp := true
	m := newTestMonitor(mailbox, true, &dbUp, &aiHealthState{})
	ctx := context.Background()
	now := time.Now()

	// Tick 1: healthy, starting state healthy => no transition, no alerts.
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin1.ID, notificationTypeOpsAlert); c != 0 {
		t.Fatalf("healthy tick alerted admin1: %d", c)
	}
	if mailbox.count() != 0 {
		t.Fatalf("healthy tick emailed: %d", mailbox.count())
	}

	// Tick 2: DB goes down => degraded transition => one alert per admin + email.
	dbUp = false
	m.runOnce(ctx, now)
	for _, a := range []uuid.UUID{admin1.ID, admin2.ID} {
		if c := opsNotifCount(t, a, notificationTypeOpsAlert); c != 1 {
			t.Fatalf("admin %s ops_alert count = %d, want 1", a, c)
		}
	}
	if c := opsNotifCount(t, nonAdmin.ID, notificationTypeOpsAlert); c != 0 {
		t.Fatalf("non-admin received ops_alert: %d", c)
	}
	if mailbox.count() != 2 {
		t.Fatalf("degrade emails = %d, want 2 (one per admin)", mailbox.count())
	}
	// Payload carries degraded + reasons.
	rows, _ := store.New(dbPool).ListNotificationsByUser(ctx,
		store.ListNotificationsByUserParams{UserID: admin1.ID, Limit: 50})
	var p map[string]any
	_ = json.Unmarshal(rows[0].Payload, &p)
	if p["degraded"] != true {
		t.Fatalf("payload degraded = %v, want true", p["degraded"])
	}

	// Tick 3: still degraded => no transition => no new alerts/emails (dedup).
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin1.ID, notificationTypeOpsAlert); c != 1 {
		t.Fatalf("repeat degraded tick re-alerted: count = %d, want 1", c)
	}
	if mailbox.count() != 2 {
		t.Fatalf("repeat degraded tick re-emailed: %d, want 2", mailbox.count())
	}

	// Tick 4: DB recovers => recovery transition => ops_recovered per admin + email.
	dbUp = true
	m.runOnce(ctx, now)
	for _, a := range []uuid.UUID{admin1.ID, admin2.ID} {
		if c := opsNotifCount(t, a, notificationTypeOpsRecovered); c != 1 {
			t.Fatalf("admin %s ops_recovered count = %d, want 1", a, c)
		}
	}
	if mailbox.count() != 4 {
		t.Fatalf("recovery emails total = %d, want 4", mailbox.count())
	}
}

// An AI-provider fatal failure (billing/auth, ai_health.go) drives the same
// transition machinery as a DB outage: one alert per admin with the AI reason
// in the payload and email, dedup on repeat ticks, and a recovery alert once
// the tracker reports healthy again.
func TestHealthMonitorAITransitions(t *testing.T) {
	requireDB(t)
	resetDB(t)
	writeFreshHeartbeat(t, time.Now()) // isolate the AI signal from backups

	admin, _ := createTestUser(t, "opsadmin-ai@example.com")
	makeAdmin(t, admin.ID)

	mailbox := &fakeMailbox{}
	dbUp := true
	ai := aiHealthState{}
	m := newTestMonitor(mailbox, true, &dbUp, &ai)
	ctx := context.Background()
	now := time.Now()

	// Tick 1: healthy — nothing.
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 0 {
		t.Fatalf("healthy tick alerted: %d", c)
	}

	// Tick 2: the AI provider goes fatal — one alert carrying the reason.
	ai = aiHealthState{Failing: true, Reason: "credit balance"}
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 1 {
		t.Fatalf("ops_alert count = %d, want 1", c)
	}
	rows, _ := store.New(dbPool).ListNotificationsByUser(ctx,
		store.ListNotificationsByUserParams{UserID: admin.ID, Limit: 50})
	var payload map[string]any
	_ = json.Unmarshal(rows[0].Payload, &payload)
	reasons, _ := json.Marshal(payload["reasons"])
	if !strings.Contains(string(reasons), "AI provider failing: credit balance") {
		t.Fatalf("alert payload reasons = %s, want the AI reason", reasons)
	}
	if mailbox.count() != 1 || !strings.Contains(mailbox.sent[0].body, "AI provider failing: credit balance") {
		t.Fatalf("email = %d sent, want 1 carrying the AI reason", mailbox.count())
	}

	// Tick 3: still failing — dedup, nothing new.
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 1 {
		t.Fatalf("repeat fatal tick re-alerted: %d", c)
	}

	// Tick 4: a successful AI call cleared the tracker — recovery alert.
	ai = aiHealthState{}
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsRecovered); c != 1 {
		t.Fatalf("ops_recovered count = %d, want 1", c)
	}
	if mailbox.count() != 2 {
		t.Fatalf("emails = %d, want 2", mailbox.count())
	}
}

// A second outage arriving while the system is ALREADY degraded must still
// alert: the dedup keys on the reason SET, not the degraded boolean —
// otherwise a fatal AI failure during a stale-backups window would repeat the
// silent multi-day /plan outage this feature exists to prevent.
func TestHealthMonitorAlertsOnOverlappingOutages(t *testing.T) {
	requireDB(t)
	resetDB(t)
	writeFreshHeartbeat(t, time.Now())

	admin, _ := createTestUser(t, "opsadmin-overlap@example.com")
	makeAdmin(t, admin.ID)

	mailbox := &fakeMailbox{}
	dbUp := false // outage #1: DB down from the first tick
	ai := aiHealthState{}
	m := newTestMonitor(mailbox, true, &dbUp, &ai)
	ctx := context.Background()
	now := time.Now()

	// Tick 1: DB down — first degraded alert.
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 1 {
		t.Fatalf("tick1 ops_alert = %d, want 1", c)
	}

	// Tick 2: the AI provider goes fatal WHILE still degraded — the reason set
	// changed, so a fresh alert fires carrying both reasons.
	ai = aiHealthState{Failing: true, Reason: "credit balance"}
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 2 {
		t.Fatalf("tick2 ops_alert = %d, want 2 (overlapping outage must alert)", c)
	}
	rows, _ := store.New(dbPool).ListNotificationsByUser(ctx,
		store.ListNotificationsByUserParams{UserID: admin.ID, Limit: 50})
	var payload map[string]any
	_ = json.Unmarshal(rows[0].Payload, &payload)
	reasons, _ := json.Marshal(payload["reasons"])
	if !strings.Contains(string(reasons), "AI provider failing: credit balance") ||
		!strings.Contains(string(reasons), "database unreachable") {
		t.Fatalf("overlap alert reasons = %s, want both outages", reasons)
	}

	// Tick 3: unchanged set — dedup holds.
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 2 {
		t.Fatalf("tick3 re-alerted: %d", c)
	}

	// Tick 4: AI recovers, DB still down — set changed, still degraded: a
	// fresh degraded alert with the remaining reason (an update, not recovery).
	ai = aiHealthState{}
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 3 {
		t.Fatalf("tick4 ops_alert = %d, want 3", c)
	}
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsRecovered); c != 0 {
		t.Fatalf("tick4 fired recovery while still degraded: %d", c)
	}

	// Tick 5: everything healthy — one recovery.
	dbUp = true
	m.runOnce(ctx, now)
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsRecovered); c != 1 {
		t.Fatalf("tick5 ops_recovered = %d, want 1", c)
	}
}

// With SMTP unconfigured, a transition still writes in-app notifications but
// sends no email (email is the only gated channel).
func TestHealthMonitorNoEmailWhenUnconfigured(t *testing.T) {
	requireDB(t)
	resetDB(t)
	writeFreshHeartbeat(t, time.Now())

	admin, _ := createTestUser(t, "opsadmin@example.com")
	makeAdmin(t, admin.ID)

	mailbox := &fakeMailbox{}
	dbUp := false // start degraded on first tick
	m := newTestMonitor(mailbox, false /* email off */, &dbUp, &aiHealthState{})

	m.runOnce(context.Background(), time.Now())

	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 1 {
		t.Fatalf("in-app ops_alert count = %d, want 1", c)
	}
	if mailbox.count() != 0 {
		t.Fatalf("email sent while SMTP unconfigured: %d", mailbox.count())
	}
}

// --- Uptime-history sampling (specs/uptime-history) ---------------------------

// sampleRecorder is the insertSample seam for sampling tests: records params,
// optionally failing while failWrites is set. No DB involved — sampling is a
// pure seam, which is the point of it being separate from the alerting seams.
type sampleRecorder struct {
	mu         sync.Mutex
	written    []store.InsertHealthSampleParams
	failWrites bool
}

func (r *sampleRecorder) insert(_ context.Context, p store.InsertHealthSampleParams) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.failWrites {
		return errors.New("db down")
	}
	r.written = append(r.written, p)
	return nil
}

func (r *sampleRecorder) rows() []store.InsertHealthSampleParams {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]store.InsertHealthSampleParams(nil), r.written...)
}

// newSamplingMonitor builds a DB-free monitor with alerting no-oped and the
// sampling seam wired to rec.
func newSamplingMonitor(rec *sampleRecorder, release string) *healthMonitor {
	return &healthMonitor{
		interval:     5 * time.Minute,
		release:      release,
		listAdmins:   func(context.Context) ([]store.ListAdminUsersRow, error) { return nil, nil },
		insertNotify: func(context.Context, store.InsertNotificationParams) error { return nil },
		sendEmail:    func(string, string, string) error { return nil },
		emailEnabled: func() bool { return false },
		pingDBFn:     func(context.Context) bool { return true },
		aiStateFn:    func() aiHealthState { return aiHealthState{} },
		insertSample: rec.insert,
	}
}

// Boot gap causes: same release = unexplained (crash/OOM/reboot -> downtime),
// changed release = deploy (unobserved), empty table = no gap row at all.
func TestBootstrapSamplesGapCause(t *testing.T) {
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	last := now.Add(-42 * time.Minute)

	cases := []struct {
		name        string
		lastRelease string
		bootRelease string
		wantCause   string
	}{
		{"same release is unexplained", "abc123", "abc123", healthGapUnknown},
		{"changed release is a deploy", "abc123", "def456", healthGapDeploy},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := &sampleRecorder{}
			m := newSamplingMonitor(rec, tc.bootRelease)
			m.bootstrapSamples(context.Background(), now, func(context.Context) (store.LastHealthSampleRow, error) {
				return store.LastHealthSampleRow{ObservedAt: last, Release: tc.lastRelease}, nil
			})
			rows := rec.rows()
			if len(rows) != 1 {
				t.Fatalf("wrote %d rows, want 1", len(rows))
			}
			g := rows[0]
			if g.Kind != healthSampleGap || g.GapCause == nil || *g.GapCause != tc.wantCause {
				t.Fatalf("gap row = %+v, want cause %s", g, tc.wantCause)
			}
			if !g.CoversFrom.Equal(last) || !g.ObservedAt.Equal(now) {
				t.Fatalf("gap span = [%v, %v], want [%v, %v]", g.CoversFrom, g.ObservedAt, last, now)
			}
			if !m.lastSampleAt.Equal(now) {
				t.Fatalf("lastSampleAt = %v, want %v", m.lastSampleAt, now)
			}
		})
	}

	t.Run("empty table writes nothing", func(t *testing.T) {
		rec := &sampleRecorder{}
		m := newSamplingMonitor(rec, "abc123")
		m.bootstrapSamples(context.Background(), now, func(context.Context) (store.LastHealthSampleRow, error) {
			return store.LastHealthSampleRow{}, pgx.ErrNoRows
		})
		if len(rec.rows()) != 0 {
			t.Fatalf("empty table wrote %d rows", len(rec.rows()))
		}
		if !m.lastSampleAt.Equal(now) {
			t.Fatalf("lastSampleAt = %v, want %v", m.lastSampleAt, now)
		}
	})
}

// A tick covers exactly [lastSampleAt, now] with the observed booleans, and a
// stalled sampler (gap > 2x interval) vouches only for its last interval —
// the excess becomes an explicit unknown-gap row.
func TestRecordTickIntervalsAndStall(t *testing.T) {
	base := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)

	rec := &sampleRecorder{}
	m := newSamplingMonitor(rec, "abc123")
	m.lastSampleAt = base

	m.recordTick(context.Background(), base.Add(5*time.Minute), true, false, true)
	rows := rec.rows()
	if len(rows) != 1 {
		t.Fatalf("wrote %d rows, want 1", len(rows))
	}
	tick := rows[0]
	if tick.Kind != healthSampleTick || !tick.CoversFrom.Equal(base) || !tick.ObservedAt.Equal(base.Add(5*time.Minute)) {
		t.Fatalf("tick row = %+v", tick)
	}
	if tick.DbOk == nil || !*tick.DbOk || tick.BackupsOk == nil || *tick.BackupsOk || tick.AiOk == nil || !*tick.AiOk {
		t.Fatalf("tick booleans = db:%v ai:%v backups:%v, want true/true/false", tick.DbOk, tick.AiOk, tick.BackupsOk)
	}

	// Stall: next tick lands 30 minutes later (interval is 5m). Excess is an
	// unknown gap; the tick claims only the final interval.
	stallNow := base.Add(35 * time.Minute)
	m.recordTick(context.Background(), stallNow, true, true, true)
	rows = rec.rows()
	if len(rows) != 3 {
		t.Fatalf("after stall wrote %d rows total, want 3", len(rows))
	}
	gap, tick2 := rows[1], rows[2]
	if gap.Kind != healthSampleGap || gap.GapCause == nil || *gap.GapCause != healthGapUnknown {
		t.Fatalf("stall gap row = %+v", gap)
	}
	if !gap.CoversFrom.Equal(base.Add(5*time.Minute)) || !gap.ObservedAt.Equal(stallNow.Add(-5*time.Minute)) {
		t.Fatalf("stall gap span = [%v, %v]", gap.CoversFrom, gap.ObservedAt)
	}
	if !tick2.CoversFrom.Equal(stallNow.Add(-5*time.Minute)) || !tick2.ObservedAt.Equal(stallNow) {
		t.Fatalf("post-stall tick span = [%v, %v]", tick2.CoversFrom, tick2.ObservedAt)
	}
}

// A failed write buffers the sample; the next success flushes it with its
// ORIGINAL timestamps (delayed writes of real observations, never back-dated
// inventions). The buffer is bounded: the oldest are dropped past the cap.
func TestWriteSampleBufferAndFlush(t *testing.T) {
	base := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	rec := &sampleRecorder{failWrites: true}
	m := newSamplingMonitor(rec, "abc123")
	m.lastSampleAt = base

	// Two ticks while the DB is down: nothing written, both held.
	m.recordTick(context.Background(), base.Add(5*time.Minute), false, true, true)
	m.recordTick(context.Background(), base.Add(10*time.Minute), false, true, true)
	if got := len(rec.rows()); got != 0 {
		t.Fatalf("wrote %d rows while failing, want 0", got)
	}
	if got := len(m.pending); got != 2 {
		t.Fatalf("pending = %d, want 2", got)
	}

	// DB recovers: the next tick writes itself AND flushes the held two.
	rec.failWrites = false
	m.recordTick(context.Background(), base.Add(15*time.Minute), true, true, true)
	rows := rec.rows()
	if len(rows) != 3 {
		t.Fatalf("after recovery wrote %d rows, want 3", len(rows))
	}
	if len(m.pending) != 0 {
		t.Fatalf("pending = %d after flush, want 0", len(m.pending))
	}
	// The flushed rows keep their original observation times.
	if !rows[1].ObservedAt.Equal(base.Add(5*time.Minute)) || !rows[2].ObservedAt.Equal(base.Add(10*time.Minute)) {
		t.Fatalf("flushed timestamps = %v, %v", rows[1].ObservedAt, rows[2].ObservedAt)
	}
	// And the held db_ok=false observations survived intact — the reason the
	// buffer exists: a DB outage records itself.
	if rows[1].DbOk == nil || *rows[1].DbOk {
		t.Fatalf("flushed row lost its db_ok=false: %+v", rows[1])
	}

	// Bound: overfill and confirm the oldest are dropped, newest kept.
	rec.failWrites = true
	for i := 0; i < healthSampleBufferMax+10; i++ {
		m.writeSample(context.Background(), store.InsertHealthSampleParams{
			ObservedAt: base.Add(time.Duration(i) * time.Second),
			CoversFrom: base,
			Kind:       healthSampleTick,
		})
	}
	if got := len(m.pending); got != healthSampleBufferMax {
		t.Fatalf("pending = %d, want cap %d", got, healthSampleBufferMax)
	}
	if !m.pending[len(m.pending)-1].ObservedAt.Equal(base.Add(time.Duration(healthSampleBufferMax+9) * time.Second)) {
		t.Fatalf("cap dropped the newest instead of the oldest")
	}
}

// Sampling failures never touch the alert path: with writes failing, a
// degraded transition still alerts exactly as before (and a monitor with no
// sampling seam at all — the older tests above — still runs runOnce fine).
func TestSamplingFailureDoesNotPerturbAlerts(t *testing.T) {
	requireDB(t)
	resetDB(t)
	writeFreshHeartbeat(t, time.Now())

	admin, _ := createTestUser(t, "opssample@example.com")
	makeAdmin(t, admin.ID)

	mailbox := &fakeMailbox{}
	dbUp := true
	m := newTestMonitor(mailbox, true, &dbUp, &aiHealthState{})
	rec := &sampleRecorder{failWrites: true}
	m.insertSample = rec.insert
	m.lastSampleAt = time.Now().Add(-5 * time.Minute)

	ctx := context.Background()
	m.runOnce(ctx, time.Now()) // healthy: no alert, sample write fails silently
	dbUp = false
	m.runOnce(ctx, time.Now()) // degraded transition: alert fires despite sampling failure
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 1 {
		t.Fatalf("ops_alert count with failing sample writes = %d, want 1", c)
	}
	if len(m.pending) == 0 {
		t.Fatalf("failed sample writes were not buffered")
	}
}
