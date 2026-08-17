package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

// plan_two_pass_integration_test.go — the shape turn (specs/shape-before-
// schedule): the planner proposes a trip's cities, nights and dates and waits
// for a yes before anything is saved.
//
// WHAT THESE TESTS CANNOT PROVE, said out loud so nobody reads more into a
// green run than is there: the fake Anthropic SCRIPTS the model's turns, so no
// test here shows that the MODEL withholds create_itinerary on turn 1. That is
// prompt behaviour, and the repo has been burned believing otherwise — the
// last-day arc's first prompt draft passed review and then produced prose
// contradicting its own tool call, found by a live run and by nothing else.
// The prompt sentences themselves are pinned as text in
// plan_language_integration_test.go; model restraint is a live-run acceptance
// item.
//
// What these DO pin is the server contract a shape turn depends on: a turn that
// only asks a question streams quick replies, creates NOTHING, and leaves the
// conversation resumable — and the agreement turn that follows still saves the
// trip. Those are the properties that would silently rot if the itinerary
// banner, the chat-graduation rule or the quick-reply gate changed underneath
// the flow.

// A turn that proposes the shape and asks about it: chips, no trip, and the
// chat still listed as in-progress so "later" survives the traveler closing the
// tab. GET /chats deliberately EXCLUDES chats that already produced a trip, so
// its listing doubles as proof nothing graduated.
func TestPlanShapeTurnProposesWithoutCreating(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		textThenToolTurn(
			"Here's the shape I'd suggest: Lisbon 3 nights, Porto 2, Madrid 2, trains between. Does that work?",
			"suggest_replies",
			`{"replies":["Looks good — build it","Fewer cities, more days each","Swap Porto for Seville"]}`),
		textTurn(""))

	user, token := createTestUser(t, "shapeturn@example.com")
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-shape",
		Messages: []PlanChatMessage{{Role: "user", Content: "two weeks in Portugal and Spain in September"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}

	if evs := suggestRepliesEvents(t, rec.Body.String()); len(evs) != 1 || len(evs[0]) != 3 {
		t.Fatalf("suggest_replies events = %v, want one turn of three chips", evs)
	}
	if dones := eventsOfType(planEvents(t, rec.Body.String()), "done"); len(dones) != 0 {
		t.Fatalf("done events = %d, want none — a shape turn saves nothing", len(dones))
	}

	// The claim that matters: nothing was created.
	var trips int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trips WHERE user_id = $1`, user.ID).Scan(&trips); err != nil {
		t.Fatalf("trips count: %v", err)
	}
	if trips != 0 {
		t.Fatalf("trips = %d, want 0 — the shape turn created a trip", trips)
	}

	rec = doJSON(t, "GET", "/api/v1/chats", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /chats = %d: %s", rec.Code, rec.Body.String())
	}
	var list []ChatSessionSummaryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode chat list: %v", err)
	}
	if len(list) != 1 || list[0].ChatID != "chat-shape" {
		t.Fatalf("resumable chats = %+v, want the shaping conversation", list)
	}
}

// ...and the agreement turn saves it. Separate fake, because the fake keys turn
// selection off the tool_result count in the REQUEST body — a second /plan call
// would otherwise replay the script from turn 0.
func TestPlanBuildsSpineAfterAgreement(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "agreed@example.com")

	newFakeAnthropic(t,
		textThenToolTurn(
			"Lisbon 3 nights, Porto 2, Madrid 2. Does that work?",
			"suggest_replies", `{"replies":["Looks good — build it","More time in Porto"]}`),
		textTurn(""))
	first := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-agreed",
		Messages: []PlanChatMessage{{Role: "user", Content: "two weeks in Portugal and Spain in September"}},
	})
	if first.Code != http.StatusOK {
		t.Fatalf("shape turn = %d: %s", first.Code, first.Body.String())
	}

	newFakeAnthropic(t,
		toolTurn("create_itinerary", `{"title":"Iberia","start_date":"2026-09-01","end_date":"2026-09-08","locations":[`+
			`{"name":"Time Out Market","latitude":38.70,"longitude":-9.14,"day":1,"city":"Lisbon","time_of_day":"evening"},`+
			`{"name":"Pasteis de Belem","latitude":38.69,"longitude":-9.20,"day":4,"city":"Lisbon","time_of_day":"morning"},`+
			`{"name":"Livraria Lello","latitude":41.14,"longitude":-8.61,"day":4,"city":"Porto","time_of_day":"evening"},`+
			`{"name":"Cais da Ribeira","latitude":41.14,"longitude":-8.61,"day":6,"city":"Porto","time_of_day":"morning"},`+
			`{"name":"Museo del Prado","latitude":40.41,"longitude":-3.69,"day":6,"city":"Madrid","time_of_day":"evening"}]}`),
		textTurn("Spine's up — days 2-3, 5 and 7 are open whenever you want them."))
	second := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-agreed",
		Messages: []PlanChatMessage{
			{Role: "user", Content: "two weeks in Portugal and Spain in September"},
			{Role: "assistant", Content: "Lisbon 3 nights, Porto 2, Madrid 2. Does that work?"},
			{Role: "user", Content: "Looks good — build it"},
		},
	})
	if second.Code != http.StatusOK {
		t.Fatalf("build turn = %d: %s", second.Code, second.Body.String())
	}
	dones := eventsOfType(planEvents(t, second.Body.String()), "done")
	if len(dones) != 1 {
		t.Fatalf("done events = %d, want 1", len(dones))
	}
	tripID, _ := eventData(dones[0])["trip_id"].(string)
	if tripID == "" {
		t.Fatal("done event carried no trip_id")
	}

	// Five places for three cities — 2N-1, the spine's arithmetic.
	var items int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM itinerary_items WHERE trip_id = $1`, tripID).Scan(&items); err != nil {
		t.Fatalf("item count: %v", err)
	}
	if items != 5 {
		t.Fatalf("items = %d, want 5", items)
	}

	// The end date is the one that was agreed, NOT the highest item day (6).
	// This is the whole reason create_itinerary refuses a one-sided date pair:
	// derived, this trip would end 2026-09-06 and Madrid would lose two nights.
	var start, end string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT start_date::text, end_date::text FROM trips WHERE id = $1`, tripID).Scan(&start, &end); err != nil {
		t.Fatalf("trip dates: %v", err)
	}
	if start != "2026-09-01" || end != "2026-09-08" {
		t.Fatalf("trip dates = %s/%s, want 2026-09-01/2026-09-08", start, end)
	}
}
