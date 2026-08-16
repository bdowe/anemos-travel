package main

// set_trip_description (specs/trip-description): a saved trip's prose overview.
// The case that motivated it is the stale one — a description written for a
// three-city trip after the trip grew to five — and the case that constrains it
// is the traveler's own words, which the planner may offer to rewrite but never
// replace on its own initiative.

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

func summaryOf(t *testing.T, tripID string) (summary, source *string) {
	t.Helper()
	if err := dbPool.QueryRow(context.Background(),
		`SELECT summary, summary_source FROM trips WHERE id = $1`, tripID).
		Scan(&summary, &source); err != nil {
		t.Fatalf("read trip summary: %v", err)
	}
	return summary, source
}

// descriptionInput builds the tool payload, so every test states both required
// fields and none can accidentally rely on a zero-valued reason.
func descriptionInput(text, reason string) json.RawMessage {
	b, _ := json.Marshal(map[string]string{"description": text, "reason": reason})
	return b
}

// tripForDescription saves a trip through the real create path, so its
// summary_source is whatever persistTrip actually stamps rather than a value the
// test asserts into place.
func tripForDescription(t *testing.T, owner uuid.UUID, chatID, summary string) (*planSession, string) {
	t.Helper()
	tripID, _, err := persistTrip(context.Background(), owner, chatID,
		"Sicily Loop", summary, "2026-09-12", "2026-09-22", "", tripEndpoints{},
		[]map[string]any{{"name": "Teatro Massimo", "city": "Palermo"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}
	s, _ := testPlanSession(true, owner)
	s.req.ChatID = chatID
	return s, tripID
}

// The headline case: the planner rewrites the blurb it wrote itself because the
// trip changed under it. Nobody has to ask.
func TestSetTripDescriptionRefreshesAgentProse(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, _ := createTestUser(t, "descagent@example.com")
	s, tripID := tripForDescription(t, user.ID, "chat-desc-agent", "Three days around Palermo.")

	msg, isErr := runSetTripDescriptionTool(s, descriptionInput(
		"Ten days circling Sicily, from Palermo's markets to Catania.", summaryReasonTripChanged))
	if isErr {
		t.Fatalf("refresh refused: %s", msg)
	}

	got, source := summaryOf(t, tripID)
	if got == nil || *got != "Ten days circling Sicily, from Palermo's markets to Catania." {
		t.Fatalf("summary = %v, want the new description", got)
	}
	if source == nil || *source != summarySourceAgent {
		t.Fatalf("summary_source = %v, want %q", source, summarySourceAgent)
	}
	// The result has to state what the trip now says: "updated" with no derived
	// state is what let a wrong mental model survive successful calls before.
	if !strings.Contains(msg, "circling Sicily") {
		t.Fatalf("result does not quote the stored description: %s", msg)
	}
}

// The invariant migration 00070 exists for: prose a person wrote is not the
// planner's to replace on a hunch. The refusal must also SAY what is there, so
// the model can offer the change instead of guessing again.
func TestSetTripDescriptionRefusesToOverwriteTravelerProse(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "desctraveler@example.com")
	s, tripID := tripForDescription(t, user.ID, "chat-desc-traveler", "Ten days in Sicily.")

	// The traveler edits it on the trip page — the only writer of 'traveler'.
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID, token,
		map[string]any{"summary": "Our 10th anniversary, finally in Sicily."})
	if rec.Code != 200 {
		t.Fatalf("patch summary = %d: %s", rec.Code, rec.Body.String())
	}

	msg, isErr := runSetTripDescriptionTool(s, descriptionInput(
		"Ten days circling Sicily.", summaryReasonTripChanged))
	if !isErr {
		t.Fatalf("planner overwrote the traveler's description: %s", msg)
	}
	if !strings.Contains(msg, "anniversary") {
		t.Fatalf("refusal does not quote what is stored, so the model can't offer a change: %s", msg)
	}
	if !strings.Contains(msg, summaryReasonAsked) {
		t.Fatalf("refusal does not name the next move: %s", msg)
	}
	// Nothing written: a refusal that half-applied would be worse than either.
	got, source := summaryOf(t, tripID)
	if got == nil || *got != "Our 10th anniversary, finally in Sicily." {
		t.Fatalf("summary = %v, want the traveler's words untouched", got)
	}
	if source == nil || *source != summarySourceTraveler {
		t.Fatalf("summary_source = %v, want it still %q", source, summarySourceTraveler)
	}
}

// ...but an explicit request always wins. The traveler asking for a rewrite is
// not the planner acting on its own initiative.
func TestSetTripDescriptionRewritesTravelerProseWhenAsked(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "descasked@example.com")
	s, tripID := tripForDescription(t, user.ID, "chat-desc-asked", "Ten days in Sicily.")

	rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID, token,
		map[string]any{"summary": "Our anniversary trip."})
	if rec.Code != 200 {
		t.Fatalf("patch summary = %d: %s", rec.Code, rec.Body.String())
	}

	msg, isErr := runSetTripDescriptionTool(s, descriptionInput(
		"Our 10th anniversary, ten days circling Sicily.", summaryReasonAsked))
	if isErr {
		t.Fatalf("requested rewrite refused: %s", msg)
	}
	got, source := summaryOf(t, tripID)
	if got == nil || *got != "Our 10th anniversary, ten days circling Sicily." {
		t.Fatalf("summary = %v, want the requested rewrite", got)
	}
	// The planner composed these words, so it now owns them — stamping
	// 'traveler' here would freeze the blurb against future refreshes.
	if source == nil || *source != summarySourceAgent {
		t.Fatalf("summary_source = %v, want %q", source, summarySourceAgent)
	}
}

// Removing the description is the traveler's call, and it STAYS removed: the
// (NULL summary, 'traveler' source) pair is what stops the next reshape
// helpfully adding one back.
func TestSetTripDescriptionRespectsADeliberateRemoval(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "descremoved@example.com")
	s, tripID := tripForDescription(t, user.ID, "chat-desc-removed", "Ten days in Sicily.")

	rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID, token, map[string]any{"summary": ""})
	if rec.Code != 200 {
		t.Fatalf("clear summary = %d: %s", rec.Code, rec.Body.String())
	}
	if got, source := summaryOf(t, tripID); got != nil {
		t.Fatalf("summary = %v, want NULL after an explicit clear (source %v)", got, source)
	}

	msg, isErr := runSetTripDescriptionTool(s, descriptionInput(
		"Ten days circling Sicily.", summaryReasonTripChanged))
	if !isErr {
		t.Fatalf("planner re-added a description the traveler deleted: %s", msg)
	}
	if got, _ := summaryOf(t, tripID); got != nil {
		t.Fatalf("summary = %v, want it still removed", got)
	}
}

// The planner may not decide a trip should have no description.
func TestSetTripDescriptionRefusesToClearOnItsOwnInitiative(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, _ := createTestUser(t, "descclear@example.com")
	s, tripID := tripForDescription(t, user.ID, "chat-desc-clear", "Ten days in Sicily.")

	msg, isErr := runSetTripDescriptionTool(s, descriptionInput("", summaryReasonTripChanged))
	if !isErr {
		t.Fatalf("planner cleared a description unasked: %s", msg)
	}
	if got, _ := summaryOf(t, tripID); got == nil || *got != "Ten days in Sicily." {
		t.Fatalf("summary = %v, want it untouched", got)
	}
}

// An unrecognized reason is refused rather than defaulted: defaulting it would
// pick a side on the one question the tool exists to make explicit.
func TestSetTripDescriptionRequiresAKnownReason(t *testing.T) {
	s, _ := testPlanSession(true, uuid.New())
	for _, reason := range []string{"", "because", "TRIP_CHANGED"} {
		msg, isErr := runSetTripDescriptionTool(s, descriptionInput("A new blurb.", reason))
		if !isErr {
			t.Fatalf("reason %q accepted: %s", reason, msg)
		}
		if !strings.Contains(msg, summaryReasonAsked) || !strings.Contains(msg, summaryReasonTripChanged) {
			t.Fatalf("reason %q: refusal does not name the valid values: %s", reason, msg)
		}
	}
}

func TestSetTripDescriptionAnonymous(t *testing.T) {
	s, _ := testPlanSession(false, uuid.Nil)
	msg, isErr := runSetTripDescriptionTool(s, descriptionInput("A new blurb.", summaryReasonAsked))
	if !isErr {
		t.Fatalf("anonymous session wrote a description: %s", msg)
	}
	if !strings.Contains(msg, "isn't signed in") {
		t.Fatalf("unexpected anonymous refusal: %s", msg)
	}
}

// Before a trip exists the answer is create_itinerary's own `summary`, not a
// second place to stage the same string.
func TestSetTripDescriptionWithNoSavedTripPointsAtCreateItinerary(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, _ := createTestUser(t, "descnotrip@example.com")
	s, _ := testPlanSession(true, user.ID)
	s.req.ChatID = "chat-desc-none"

	msg, isErr := runSetTripDescriptionTool(s, descriptionInput("A new blurb.", summaryReasonAsked))
	if !isErr {
		t.Fatalf("wrote a description with no saved trip: %s", msg)
	}
	if !strings.Contains(msg, "create_itinerary") {
		t.Fatalf("refusal does not name the next move: %s", msg)
	}
}

func TestSetTripDescriptionRejectsOverlongProse(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, _ := createTestUser(t, "desclong@example.com")
	s, tripID := tripForDescription(t, user.ID, "chat-desc-long", "Ten days in Sicily.")

	msg, isErr := runSetTripDescriptionTool(s, descriptionInput(
		strings.Repeat("x", maxSummaryLen+1), summaryReasonAsked))
	if !isErr {
		t.Fatalf("overlong description accepted: %s", msg)
	}
	if got, _ := summaryOf(t, tripID); got == nil || *got != "Ten days in Sicily." {
		t.Fatalf("summary = %v, want it untouched", got)
	}
}

// The line has to actually reach get_trip's output, not merely exist: a
// description the model cannot read is one it improvises about, which is the
// whole reason this tool needed writing. Asserted on the real tool output rather
// than on tripDescriptionSummary alone, so deleting the call site fails here.
func TestGetTripShowsTheDescriptionAndItsAuthor(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "descgettrip@example.com")
	_, tripID := tripForDescription(t, user.ID, "chat-desc-gettrip", "Ten days circling Sicily.")
	id, err := uuid.Parse(tripID)
	if err != nil {
		t.Fatalf("parse trip id: %v", err)
	}

	detail, isErr := runGetTripTool(context.Background(), true, user.ID, nil,
		json.RawMessage(`{"trip_id":"`+tripID+`"}`))
	if isErr {
		t.Fatalf("get_trip errored: %s", detail)
	}
	if !strings.Contains(detail, "Ten days circling Sicily.") {
		t.Fatalf("get_trip does not show the description: %s", detail)
	}
	if !strings.Contains(detail, "written by the assistant") {
		t.Fatalf("get_trip does not say whose words they are: %s", detail)
	}

	// After the traveler edits it, the same read must report the new author —
	// otherwise the planner would still believe the prose is its own to replace.
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID, token,
		map[string]any{"summary": "Our anniversary in Sicily."}); rec.Code != 200 {
		t.Fatalf("patch summary = %d: %s", rec.Code, rec.Body.String())
	}
	detail, isErr = runGetTripTool(context.Background(), true, user.ID, &id, json.RawMessage(`{}`))
	if isErr {
		t.Fatalf("get_trip (bound) errored: %s", detail)
	}
	if !strings.Contains(detail, "the traveler wrote this themselves") {
		t.Fatalf("get_trip does not flag the traveler's authorship: %s", detail)
	}
}

// get_trip must show the description AND its author — the model wrote this text
// and then could neither read it back nor tell whose words are there now. All
// four cases are distinct on purpose: "none yet" and "removed on purpose" call
// for opposite behaviour.
func TestTripDescriptionSummaryIsExplicitAboutAbsence(t *testing.T) {
	ptr := func(s string) *string { return &s }
	cases := []struct {
		name string
		trip store.Trip
		want string
	}{
		{"agent wrote it", store.Trip{Summary: ptr("Ten days in Sicily."), SummarySource: ptr(summarySourceAgent)}, "written by the assistant"},
		{"traveler wrote it", store.Trip{Summary: ptr("Our anniversary."), SummarySource: ptr(summarySourceTraveler)}, "the traveler wrote this themselves"},
		{"traveler removed it", store.Trip{SummarySource: ptr(summarySourceTraveler)}, "removed it on purpose"},
		{"never written", store.Trip{}, "none yet"},
		// Pre-00070 prose: provably not the traveler's, because no human writer
		// existed. It must read as refreshable, not as protected.
		{"untracked author", store.Trip{Summary: ptr("Legacy blurb.")}, "written by the assistant"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tripDescriptionSummary(tc.trip)
			if !strings.Contains(strings.ToLower(got), strings.ToLower(tc.want)) {
				t.Fatalf("summary = %q, want it to mention %q", got, tc.want)
			}
		})
	}
}
