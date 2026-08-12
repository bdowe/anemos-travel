package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// --- pure builder unit tests ---

func TestBuildTripReminderEmail(t *testing.T) {
	tripURL := "https://app.example.com/trips/abc"
	unsub := "https://app.example.com/api/v1/unsubscribe/tok"

	// 3-days-out variant.
	subject, body := buildTripReminderEmail("en", reminderKindSoon, "Athens Hop", "2026-09-01", tripURL, unsub)
	if !strings.Contains(subject, "Athens Hop") || !strings.Contains(subject, "3 days") {
		t.Fatalf("soon subject = %q", subject)
	}
	for _, want := range []string{"Athens Hop", "3 days", "2026-09-01", tripURL, unsub} {
		if !strings.Contains(body, want) {
			t.Fatalf("soon body missing %q:\n%s", want, body)
		}
	}

	// Day-of variant.
	subject, body = buildTripReminderEmail("en", reminderKindToday, "Athens Hop", "2026-09-01", tripURL, unsub)
	if !strings.Contains(subject, "starts today") {
		t.Fatalf("today subject = %q", subject)
	}
	if !strings.Contains(body, "Today's the day") || !strings.Contains(body, tripURL) || !strings.Contains(body, unsub) {
		t.Fatalf("today body:\n%s", body)
	}
}

func TestBuildWeeklyNudgeEmail(t *testing.T) {
	appURL := "https://app.example.com/"
	unsub := "https://app.example.com/api/v1/unsubscribe/tok"

	subject, body := buildWeeklyNudgeEmail("en", "Brian", appURL, unsub)
	if !strings.Contains(subject, "left off") {
		t.Fatalf("subject = %q", subject)
	}
	for _, want := range []string{"Hi Brian", appURL, unsub} {
		if !strings.Contains(body, want) {
			t.Fatalf("body missing %q:\n%s", want, body)
		}
	}

	// Empty name falls back to a generic greeting.
	_, body = buildWeeklyNudgeEmail("en", "", appURL, unsub)
	if !strings.Contains(body, "Hi there") {
		t.Fatalf("generic greeting missing:\n%s", body)
	}
}

// --- stub-clock runOnce integration tests ---

// seedDepartingTrip inserts a trip departing on start (a date) for owner.
func seedDepartingTrip(t *testing.T, owner uuid.UUID, title string, start time.Time) store.Trip {
	t.Helper()
	q := store.New(dbPool)
	chat := uuid.NewString()
	trip, err := q.CreateTrip(context.Background(), store.CreateTripParams{
		UserID: owner, Title: title, ChatID: &chat,
	})
	if err != nil {
		t.Fatalf("seedDepartingTrip create: %v", err)
	}
	if _, err := q.UpdateTrip(context.Background(), store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: pgtype.Date{Time: start, Valid: true},
	}); err != nil {
		t.Fatalf("seedDepartingTrip update: %v", err)
	}
	return trip
}

func notificationsFor(t *testing.T, u uuid.UUID) []store.Notification {
	t.Helper()
	rows, err := store.New(dbPool).ListNotificationsByUser(context.Background(),
		store.ListNotificationsByUserParams{UserID: u, Limit: 20})
	if err != nil {
		t.Fatalf("list notifications: %v", err)
	}
	return rows
}

// ageTrips backdates a user's trips.updated_at by days. A BEFORE UPDATE trigger
// (trg_trips_updated_at) normally forces updated_at=now() on any UPDATE, so we
// disable it for the duration of the backdate — the only way to fabricate an
// "idle" trip in a test.
func ageTrips(t *testing.T, u uuid.UUID, days int) {
	t.Helper()
	ctx := context.Background()
	if _, err := dbPool.Exec(ctx, `ALTER TABLE trips DISABLE TRIGGER trg_trips_updated_at`); err != nil {
		t.Fatalf("disable trigger: %v", err)
	}
	if _, err := dbPool.Exec(ctx,
		`UPDATE trips SET updated_at = now() - make_interval(days => $2) WHERE user_id = $1`, u, days); err != nil {
		t.Fatalf("age trips: %v", err)
	}
	if _, err := dbPool.Exec(ctx, `ALTER TABLE trips ENABLE TRIGGER trg_trips_updated_at`); err != nil {
		t.Fatalf("enable trigger: %v", err)
	}
}

func reminderSendCount(t *testing.T, u uuid.UUID) int {
	t.Helper()
	var n int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM reminder_sends WHERE user_id = $1`, u).Scan(&n); err != nil {
		t.Fatalf("count reminder_sends: %v", err)
	}
	return n
}

// A dated trip departing in 3 days yields exactly one trip_soon notification
// and a reminder_sends row; a second runOnce at the same clock re-sends nothing
// (dedup). An opted-out user still gets the in-app notification.
func TestReengagementTripSoon(t *testing.T) {
	resetDB(t)
	now := time.Date(2026, 9, 1, 9, 0, 0, 0, time.UTC)

	user, _ := createTestUser(t, "soon@example.com")
	seedDepartingTrip(t, user.ID, "Kyoto Loop", now.AddDate(0, 0, reminderDaysSoon))

	// An opted-out user with a trip departing in 3 days: notification, no email.
	optOut, _ := createTestUser(t, "optout@example.com")
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE users SET reminders_opt_out = true WHERE id = $1`, optOut.ID); err != nil {
		t.Fatalf("set opt-out: %v", err)
	}
	seedDepartingTrip(t, optOut.ID, "Lisbon Weekend", now.AddDate(0, 0, reminderDaysSoon))

	c := &reengagementChecker{batchSize: 200}
	c.runOnce(context.Background(), now)

	for _, u := range []uuid.UUID{user.ID, optOut.ID} {
		got := notificationsFor(t, u)
		if len(got) != 1 {
			t.Fatalf("user %s: notifications = %d, want 1", u, len(got))
		}
		if got[0].Type != notificationTypeTripReminder {
			t.Fatalf("type = %q, want trip_reminder", got[0].Type)
		}
		var p map[string]any
		if err := json.Unmarshal(got[0].Payload, &p); err != nil {
			t.Fatalf("payload not JSON: %v", err)
		}
		if p["kind"] != reminderKindSoon || p["days_until"] != float64(reminderDaysSoon) {
			t.Fatalf("payload wrong: %v", p)
		}
		if reminderSendCount(t, u) != 1 {
			t.Fatalf("user %s reminder_sends = %d, want 1", u, reminderSendCount(t, u))
		}
	}

	// Re-run at the same clock: dedup — no second notification, no new send.
	c.runOnce(context.Background(), now)
	if n := len(notificationsFor(t, user.ID)); n != 1 {
		t.Fatalf("after re-run notifications = %d, want 1 (dedup)", n)
	}
	if reminderSendCount(t, user.ID) != 1 {
		t.Fatalf("after re-run reminder_sends = %d, want 1", reminderSendCount(t, user.ID))
	}
}

// A dated trip departing today yields a trip_today notification (distinct kind
// from trip_soon), so a trip reminded 3-days-out reminds again on the day.
func TestReengagementTripToday(t *testing.T) {
	resetDB(t)
	now := time.Date(2026, 9, 4, 9, 0, 0, 0, time.UTC)

	user, _ := createTestUser(t, "today@example.com")
	seedDepartingTrip(t, user.ID, "Rome Today", now)

	c := &reengagementChecker{batchSize: 200}
	c.runOnce(context.Background(), now)

	got := notificationsFor(t, user.ID)
	if len(got) != 1 {
		t.Fatalf("notifications = %d, want 1", len(got))
	}
	var p map[string]any
	_ = json.Unmarshal(got[0].Payload, &p)
	if p["kind"] != reminderKindToday || p["days_until"] != float64(reminderDaysToday) {
		t.Fatalf("payload = %v, want trip_today/0", p)
	}
}

// An idle user with an undated trip gets one weekly_nudge notification and a
// last_weekly_nudge_at stamp; a re-run within the week sends nothing.
func TestReengagementWeeklyNudge(t *testing.T) {
	resetDB(t)
	now := time.Now()

	user, _ := createTestUser(t, "idle@example.com")
	// An undated trip whose updated_at is well older than the 7-day idle cutoff.
	createTestTrip(t, user.ID, 0)
	ageTrips(t, user.ID, 30)

	c := &reengagementChecker{batchSize: 200}
	c.runOnce(context.Background(), now)

	got := notificationsFor(t, user.ID)
	if len(got) != 1 || got[0].Type != notificationTypeWeeklyNudge {
		t.Fatalf("weekly nudge notifications = %+v, want 1 weekly_nudge", got)
	}
	var stamped bool
	if err := dbPool.QueryRow(context.Background(),
		`SELECT last_weekly_nudge_at IS NOT NULL FROM users WHERE id = $1`, user.ID).Scan(&stamped); err != nil {
		t.Fatalf("read stamp: %v", err)
	}
	if !stamped {
		t.Fatal("last_weekly_nudge_at not set")
	}

	// Re-run within the week: the freshly stamped guard suppresses a re-nudge.
	c.runOnce(context.Background(), now)
	if n := len(notificationsFor(t, user.ID)); n != 1 {
		t.Fatalf("re-run within week nudged again: %d notifications, want 1", n)
	}
}

// A recently-active user with an undated trip is NOT nudged (idle guard), and
// a user with no unfinished work is never nudged.
func TestReengagementWeeklyNudgeSkips(t *testing.T) {
	resetDB(t)
	now := time.Now()

	// Active: undated trip touched just now (default updated_at = now).
	active, _ := createTestUser(t, "active@example.com")
	createTestTrip(t, active.ID, 0)

	// No unfinished work: a user with no trips and no plan chats.
	empty, _ := createTestUser(t, "empty@example.com")

	c := &reengagementChecker{batchSize: 200}
	c.runOnce(context.Background(), now)

	if n := len(notificationsFor(t, active.ID)); n != 0 {
		t.Fatalf("recently-active user nudged: %d notifications, want 0", n)
	}
	if n := len(notificationsFor(t, empty.ID)); n != 0 {
		t.Fatalf("user with no work nudged: %d notifications, want 0", n)
	}
}

// --- derived unfinished-work predicate (specs/retire-trip-status) ---

// seedBookingTodo inserts one booking todo for the trip, booked or not.
func seedBookingTodo(t *testing.T, tripID uuid.UUID, booked bool) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`INSERT INTO booking_todos (trip_id, kind, todo_key, title, booked)
		 VALUES ($1, 'transport', 'transport:test', 'Test leg', $2)`, tripID, booked); err != nil {
		t.Fatalf("seed booking todo: %v", err)
	}
}

// An idle user whose only trip is dated and upcoming still qualifies for the
// weekly nudge through the trip's unbooked booking todo.
func TestReengagementWeeklyNudgeUnbookedTodo(t *testing.T) {
	resetDB(t)
	now := time.Now()

	user, _ := createTestUser(t, "todo@example.com")
	trip := seedDepartingTrip(t, user.ID, "Oslo Later", now.AddDate(0, 0, 30))
	seedBookingTodo(t, trip.ID, false)
	ageTrips(t, user.ID, 30)

	c := &reengagementChecker{batchSize: 200}
	c.runOnce(context.Background(), now)

	got := notificationsFor(t, user.ID)
	if len(got) != 1 || got[0].Type != notificationTypeWeeklyNudge {
		t.Fatalf("unbooked-todo user notifications = %+v, want 1 weekly_nudge", got)
	}
}

// The same shape with the todo already booked is finished work: dated trip,
// nothing left to book — no nudge.
func TestReengagementWeeklyNudgeBookedTodoSkips(t *testing.T) {
	resetDB(t)
	now := time.Now()

	user, _ := createTestUser(t, "booked@example.com")
	trip := seedDepartingTrip(t, user.ID, "Oslo Sorted", now.AddDate(0, 0, 30))
	seedBookingTodo(t, trip.ID, true)
	ageTrips(t, user.ID, 30)

	c := &reengagementChecker{batchSize: 200}
	c.runOnce(context.Background(), now)

	if n := len(notificationsFor(t, user.ID)); n != 0 {
		t.Fatalf("booked-todo user nudged: %d notifications, want 0", n)
	}
}

// A user whose only trip is in the past is done, not stuck — never nudged,
// even with an unbooked todo left on the old trip (pins the narrowing from
// the status-era predicate, which kept such users nudge-eligible forever).
func TestReengagementWeeklyNudgePastTripSkips(t *testing.T) {
	resetDB(t)
	now := time.Now()

	user, _ := createTestUser(t, "past@example.com")
	trip := seedDepartingTrip(t, user.ID, "Rome Was", now.AddDate(0, 0, -30))
	seedBookingTodo(t, trip.ID, false)
	ageTrips(t, user.ID, 30)

	c := &reengagementChecker{batchSize: 200}
	c.runOnce(context.Background(), now)

	if n := len(notificationsFor(t, user.ID)); n != 0 {
		t.Fatalf("past-trip-only user nudged: %d notifications, want 0", n)
	}
}
