package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Re-engagement checkers (Wave 16): two background jobs that mirror the
// price-alert checker's shape (own goroutine, env-cadence ticker, jittered
// first run, dbPool-nil guard, pure email builders + fire-and-forget sends) but
// run on their own loop, not the alert loop.
//
//   - Trip reminders fire 3 days before departure ('trip_soon') and on the
//     departure day ('trip_today') for planned, dated trips.
//   - A weekly nudge re-invites users who started planning (a draft trip or a
//     resumable plan chat) but have gone quiet for a week.
//
// Posture (Brian): all three are opt-out (default on), and the in-app
// notification is ALWAYS written regardless of the email opt-out — only the
// email is gated. Idempotency lives in the DB: reminder_sends (per user,
// lineage, kind) and users.last_weekly_nudge_at, both written BEFORE the send
// so a crashed/retried tick can never double-notify (the alert checker's "mark
// before send" rule).

const (
	reminderKindSoon  = "trip_soon"
	reminderKindToday = "trip_today"

	reminderDaysSoon  = 3
	reminderDaysToday = 0

	notificationTypeTripReminder = "trip_reminder"
	notificationTypeWeeklyNudge  = "weekly_nudge"

	defaultReengagementTickHours = 24
	reengagementBatchSize        = 200
	nudgeIdleDays                = 7
)

type reengagementChecker struct {
	interval  time.Duration
	batchSize int
}

// startReengagementChecker launches the background loop. No-ops (with a log
// line) when persistence is unavailable, exactly like startAlertChecker; the
// jobs resume on next boot once a database is configured.
func startReengagementChecker(ctx context.Context) {
	if dbPool == nil {
		log.Printf("re-engagement: checker disabled (no database)")
		return
	}
	c := &reengagementChecker{
		interval:  time.Duration(envInt("REENGAGEMENT_TICK_HOURS", defaultReengagementTickHours)) * time.Hour,
		batchSize: reengagementBatchSize,
	}
	go c.run(ctx)
	log.Printf("re-engagement: checker started (tick %s)", c.interval)
}

func (c *reengagementChecker) run(ctx context.Context) {
	// Jitter the first tick so restarts don't synchronize a burst of sends.
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Duration(rand.Int63n(int64(c.interval)))):
	}
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()
	for {
		// Guard each tick: a panic in one cycle must not kill the ticker (and
		// with it the whole process). Log-and-continue to the next tick.
		safeRun("re-engagement checker tick", func() { c.runOnce(ctx, time.Now()) })
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// runOnce performs one re-engagement cycle. The injectable clock is the
// testable seam: trip-reminder due dates derive from now's calendar date and
// the weekly-nudge cutoff from now-7d.
func (c *reengagementChecker) runOnce(ctx context.Context, now time.Time) {
	q := store.New(dbPool)
	c.runTripReminders(ctx, q, now)
	c.runWeeklyNudge(ctx, q, now)
}

// --- trip reminders ---

func (c *reengagementChecker) runTripReminders(ctx context.Context, q *store.Queries, now time.Time) {
	// Compare on calendar date (UTC) against the trips.start_date DATE column.
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	kinds := []struct {
		kind      string
		daysUntil int
	}{
		{reminderKindSoon, reminderDaysSoon},
		{reminderKindToday, reminderDaysToday},
	}
	for _, k := range kinds {
		if ctx.Err() != nil {
			return
		}
		target := today.AddDate(0, 0, k.daysUntil)
		rows, err := q.ListTripsForReminder(ctx, store.ListTripsForReminderParams{
			TargetDate: pgtype.Date{Time: target, Valid: true},
			Kind:       k.kind,
			RowLimit:   int32(c.batchSize),
		})
		if err != nil {
			log.Printf("re-engagement: list %s trips failed: %v", k.kind, err)
			continue
		}
		for _, row := range rows {
			c.sendTripReminder(ctx, q, row, k.kind, k.daysUntil)
		}
	}
}

// sendTripReminder records the send (the idempotency guard) BEFORE any email,
// then ALWAYS writes the in-app notification, and only emails opted-in users.
// Recording first mirrors the alert checker's mark-before-send: a tick that
// crashes after the record is set never re-fires this (user, lineage, kind);
// the worst case is a lost notification, never a duplicate.
func (c *reengagementChecker) sendTripReminder(ctx context.Context, q *store.Queries, row store.ListTripsForReminderRow, kind string, daysUntil int) {
	if err := q.RecordReminderSent(ctx, store.RecordReminderSentParams{
		UserID:         row.UserID,
		TripLineageKey: row.LineageKey,
		Kind:           kind,
	}); err != nil {
		log.Printf("re-engagement: record %s for %s failed: %v", kind, row.UserID, err)
		return
	}
	payload := tripReminderPayload(row, kind, daysUntil)
	if _, err := q.InsertNotification(ctx, store.InsertNotificationParams{
		UserID:  row.UserID,
		Type:    notificationTypeTripReminder,
		Payload: payload,
		TripID:  pgtype.UUID{Bytes: row.ID, Valid: true},
	}); err != nil {
		log.Printf("re-engagement: insert %s notification for %s failed: %v", kind, row.UserID, err)
	}
	if !row.RemindersOptOut {
		safeGo("sendReminderEmail", func() { sendReminderEmail(row, kind) })
	}
}

// --- weekly nudge ---

func (c *reengagementChecker) runWeeklyNudge(ctx context.Context, q *store.Queries, now time.Time) {
	cutoff := now.AddDate(0, 0, -nudgeIdleDays)
	rows, err := q.ListUsersForWeeklyNudge(ctx, store.ListUsersForWeeklyNudgeParams{
		Cutoff:   pgTimestamptz(cutoff),
		RowLimit: int32(c.batchSize),
	})
	if err != nil {
		log.Printf("re-engagement: list weekly-nudge users failed: %v", err)
		return
	}
	for _, row := range rows {
		if ctx.Err() != nil {
			return
		}
		c.sendWeeklyNudge(ctx, q, row)
	}
}

// sendWeeklyNudge stamps last_weekly_nudge_at (the once-a-week guard) BEFORE any
// email, then ALWAYS writes the in-app nudge, and only emails opted-in users.
// Same crash-safety ordering as sendTripReminder.
func (c *reengagementChecker) sendWeeklyNudge(ctx context.Context, q *store.Queries, row store.ListUsersForWeeklyNudgeRow) {
	if err := q.TouchWeeklyNudge(ctx, row.ID); err != nil {
		log.Printf("re-engagement: touch weekly nudge for %s failed: %v", row.ID, err)
		return
	}
	if _, err := q.InsertNotification(ctx, store.InsertNotificationParams{
		UserID:  row.ID,
		Type:    notificationTypeWeeklyNudge,
		Payload: weeklyNudgePayload(),
	}); err != nil {
		log.Printf("re-engagement: insert weekly nudge for %s failed: %v", row.ID, err)
	}
	if !row.NudgesOptOut {
		safeGo("sendNudgeEmail", func() { sendNudgeEmail(row) })
	}
}

// --- payload builders (in-app notification render bags) ---

// tripReminderPayload carries everything the notification tile needs to render
// without a join, the same self-describing convention as priceDropPayload.
func tripReminderPayload(row store.ListTripsForReminderRow, kind string, daysUntil int) []byte {
	m := map[string]any{
		"kind":       kind,
		"trip_title": row.Title,
		"start_date": dateString(row.StartDate),
		"days_until": daysUntil,
	}
	b, err := json.Marshal(m)
	if err != nil {
		return []byte(`{}`)
	}
	return b
}

func weeklyNudgePayload() []byte {
	b, err := json.Marshal(map[string]any{"reason": "resume_planning"})
	if err != nil {
		return []byte(`{}`)
	}
	return b
}

// --- email builders (pure, unit-tested) ---

// buildTripReminderEmail renders the trip-reminder email in the recipient's
// language. Pure — unit-tested.
func buildTripReminderEmail(locale, kind, tripTitle, startDate, tripURL, unsubscribeURL string) (subject, body string) {
	var b strings.Builder
	if kind == reminderKindToday {
		subject = tr(locale, "email.reminder.subject_today", tripTitle)
		fmt.Fprintf(&b, "%s\n\n", tr(locale, "email.reminder.lead_today", tripTitle))
	} else {
		subject = tr(locale, "email.reminder.subject_soon", tripTitle, reminderDaysSoon)
		fmt.Fprintf(&b, "%s\n\n", tr(locale, "email.reminder.lead_soon", tripTitle, reminderDaysSoon))
	}
	if startDate != "" {
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.reminder.departure", startDate))
	}
	fmt.Fprintf(&b, "\n%s\n", tr(locale, "email.reminder.open", tripURL))
	fmt.Fprintf(&b, "\n%s\n", tr(locale, "email.reminder.signoff"))
	fmt.Fprintf(&b, "\n%s\n", tr(locale, "email.reminder.unsubscribe", unsubscribeURL))
	return subject, b.String()
}

// buildWeeklyNudgeEmail renders the weekly planning nudge in the recipient's
// language. Pure — unit-tested. name is the recipient's display name
// ("" => a generic greeting).
func buildWeeklyNudgeEmail(locale, name, appURL, unsubscribeURL string) (subject, body string) {
	subject = tr(locale, "email.nudge.subject")
	var b strings.Builder
	if strings.TrimSpace(name) != "" {
		fmt.Fprintf(&b, "%s\n\n", tr(locale, "email.nudge.greeting", name))
	} else {
		fmt.Fprintf(&b, "%s\n\n", tr(locale, "email.nudge.greeting_generic"))
	}
	fmt.Fprintf(&b, "%s\n\n", tr(locale, "email.nudge.body"))
	fmt.Fprintf(&b, "%s\n", tr(locale, "email.nudge.resume", appURL))
	fmt.Fprintf(&b, "\n%s\n", tr(locale, "email.nudge.unsubscribe", unsubscribeURL))
	return subject, b.String()
}

func sendReminderEmail(row store.ListTripsForReminderRow, kind string) {
	tripURL := publicAppURL("trips/", row.ID.String())
	unsub := unsubscribeURL(row.UserID, unsubReminders)
	// No request context in a background tick: the language is the one the
	// account synced (ListTripsForReminder carries it on the row).
	subject, body := buildTripReminderEmail(localeOrDefault(row.Locale), kind, row.Title, dateString(row.StartDate), tripURL, unsub)
	if err := emailService.SendMarketing(row.Email, subject, body, unsub); err != nil {
		log.Printf("re-engagement: reminder email to %s failed: %v", maskEmail(row.Email), err)
	}
}

func sendNudgeEmail(row store.ListUsersForWeeklyNudgeRow) {
	appURL := publicAppURL()
	unsub := unsubscribeURL(row.ID, unsubNudges)
	name := ""
	if row.DisplayName != nil {
		name = *row.DisplayName
	}
	subject, body := buildWeeklyNudgeEmail(localeOrDefault(row.Locale), name, appURL, unsub)
	if err := emailService.SendMarketing(row.Email, subject, body, unsub); err != nil {
		log.Printf("re-engagement: nudge email to %s failed: %v", maskEmail(row.Email), err)
	}
}
