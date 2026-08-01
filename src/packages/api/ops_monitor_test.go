package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

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
