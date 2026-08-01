package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// End-to-end story of the credit-balance outage this feature exists for:
// a fatal provider failure on /plan flips the AI-health tracker, the shared
// ops verdict, and the monitor's transition alert; the next successful call
// recovers all three. DB-gated (admin notifications need the store).

func TestPlanFatalFailureDegradesOpsHealthAndRecovers(t *testing.T) {
	requireDB(t)
	resetDB(t)
	resetAIHealth(t)
	writeFreshHeartbeat(t, time.Now())

	admin, _ := createTestUser(t, "opsadmin-e2e@example.com")
	makeAdmin(t, admin.ID)

	// The exact failure prod saw: a pre-stream 400 whose message names the
	// credit balance.
	newFakeAnthropic(t, httpErrorTurn(400, "invalid_request_error",
		"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."))

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "plan me a weekend in Athens"},
	}})
	events := planEvents(t, rec.Body.String())
	errs := eventsOfType(events, "error")
	if len(errs) != 1 {
		t.Fatalf("error events = %d, want 1 (stream: %s)", len(errs), rec.Body.String())
	}
	msg, _ := eventData(errs[0])["message"].(string)
	if !strings.Contains(msg, "temporarily unavailable") {
		t.Fatalf("fatal-class SSE message = %q, want the honest temporarily-unavailable copy", msg)
	}
	if strings.Contains(msg, "credit") || strings.Contains(msg, "billing") {
		t.Fatalf("SSE message leaks provider detail: %q", msg)
	}

	// Tracker + shared verdict are failing with the reason.
	if s := aiHealth.state(); !s.Failing || s.Reason != "credit balance" {
		t.Fatalf("tracker after fatal /plan = %+v", s)
	}
	health := buildDependencyHealth(context.Background(), time.Now())
	if !health.Degraded || !strings.Contains(strings.Join(health.Reasons, "|"), "AI provider failing: credit balance") {
		t.Fatalf("ops health = degraded=%v reasons=%v", health.Degraded, health.Reasons)
	}

	// The monitor tick alerts on the transition.
	mailbox := &fakeMailbox{}
	dbUp := true
	m := newTestMonitor(mailbox, true, &dbUp, &aiHealthState{})
	m.aiStateFn = aiHealth.state
	m.runOnce(context.Background(), time.Now())
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsAlert); c != 1 {
		t.Fatalf("ops_alert count = %d, want 1", c)
	}

	// Recovery: the next successful model call clears everything.
	newFakeAnthropic(t, textTurn("Athens is lovely in September."))
	rec = runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "plan me a weekend in Athens"},
	}})
	if errs := eventsOfType(planEvents(t, rec.Body.String()), "error"); len(errs) != 0 {
		t.Fatalf("recovery turn errored: %v", errs)
	}
	if s := aiHealth.state(); s.Failing {
		t.Fatalf("tracker still failing after success: %+v", s)
	}
	if health := buildDependencyHealth(context.Background(), time.Now()); health.Degraded {
		t.Fatalf("ops health still degraded after recovery: %v", health.Reasons)
	}
	m.runOnce(context.Background(), time.Now())
	if c := opsNotifCount(t, admin.ID, notificationTypeOpsRecovered); c != 1 {
		t.Fatalf("ops_recovered count = %d, want 1", c)
	}
}

// A mid-stream transient error (the existing errorTurn shape, overloaded at
// stream-status 200) keeps the old "try again in a moment" copy and never
// touches the fatal state — transient must not alert.
func TestPlanTransientFailureDoesNotDegrade(t *testing.T) {
	resetAIHealth(t)
	newFakeAnthropic(t, errorTurn("Overloaded"))

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "hello"},
	}})
	errs := eventsOfType(planEvents(t, rec.Body.String()), "error")
	if len(errs) != 1 {
		t.Fatalf("error events = %d, want 1", len(errs))
	}
	msg, _ := eventData(errs[0])["message"].(string)
	if !strings.Contains(msg, "try again in a moment") {
		t.Fatalf("transient SSE message = %q, want the try-again copy", msg)
	}
	s := aiHealth.state()
	if s.Failing || s.FatalTotal != 0 || s.TransientTotal == 0 {
		t.Fatalf("tracker after transient = %+v", s)
	}
}
