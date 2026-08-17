package main

import (
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

// suggest_replies (specs/chat-quick-replies): a client-only emit tool at the
// registry tail. The model attaches 2-4 one-tap answers to a question turn;
// the server sanitizes and streams them as a `suggest_replies` SSE event.

// suggestRepliesEvents pulls the replies arrays out of every suggest_replies
// event in the stream, in order.
func suggestRepliesEvents(t *testing.T, body string) [][]string {
	t.Helper()
	var out [][]string
	for _, e := range eventsOfType(planEvents(t, body), "suggest_replies") {
		raw, _ := eventData(e)["replies"].([]any)
		var replies []string
		for _, r := range raw {
			if s, ok := r.(string); ok {
				replies = append(replies, s)
			}
		}
		out = append(out, replies)
	}
	return out
}

func TestPlanSuggestRepliesEmitsEvent(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("suggest_replies", `{"replies":["Mid-range budget","Luxury all the way","  ","Surprise me"]}`),
		textTurn(""))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-qr",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me something warm"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	got := suggestRepliesEvents(t, rec.Body.String())
	want := [][]string{{"Mid-range budget", "Luxury all the way", "Surprise me"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("suggest_replies events = %v, want %v", got, want)
	}

	// The meta-tool still round-trips as a normal tool: one tool_call and one
	// tool_result named suggest_replies (the new client suppresses its
	// spinner chip; stale clients add+remove it within a frame).
	for _, typ := range []string{"tool_call", "tool_result"} {
		evs := eventsOfType(events, typ)
		if len(evs) != 1 || eventData(evs[0])["name"] != "suggest_replies" {
			t.Fatalf("%s events = %v, want exactly one named suggest_replies", typ, evs)
		}
	}

	// The ack instructs the terminal iteration to end without repeating the
	// options, and the first request's tools array ends with the new tail.
	reqs := fa.requestBodies()
	if len(reqs) < 2 {
		t.Fatalf("model requests = %d, want >= 2 (tool round-trip)", len(reqs))
	}
	if !strings.Contains(string(reqs[1]), "Quick replies are now shown") {
		t.Fatal("follow-up request carries no suggest_replies ack")
	}
	var body struct {
		Tools []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(reqs[0], &body); err != nil {
		t.Fatalf("unmarshal request body: %v", err)
	}
	// Anonymous session: the date/origin/mode/description tools are authed-gated
	// and so never reach this shape. search_hotels is NOT gated — it is the one
	// tool added since find_parking that lands on the anonymous array too, which
	// is the deliberate one-time cache re-warm specs/hotel-search takes. It
	// remains the anonymous tail: set_trip_description was appended after it but
	// gated, so this array is byte-identical again.
	if n := len(body.Tools); n == 0 || body.Tools[n-1].Name != "search_hotels" {
		t.Fatalf("tools tail = %+v, want search_hotels last", body.Tools)
	}
}

func TestPlanSuggestRepliesRejectsAllInvalidInput(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("suggest_replies", `{"replies":["","   "]}`),
		textTurn("What budget suits you?"))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-qr-invalid",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me something warm"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}
	if evs := suggestRepliesEvents(t, rec.Body.String()); len(evs) != 0 {
		t.Fatalf("suggest_replies events = %v, want none for all-invalid input", evs)
	}
	// The model gets an is_error tool_result and recovers with plain text.
	reqs := fa.requestBodies()
	if len(reqs) < 2 || !strings.Contains(string(reqs[1]), `"is_error":true`) {
		t.Fatal("follow-up request carries no is_error tool_result")
	}
	if got := joinedText(planEvents(t, rec.Body.String())); got != "What budget suits you?" {
		t.Fatalf("streamed text = %q, want the recovery question", got)
	}
}

func TestPlanSuggestRepliesDuplicateCallsEmitBoth(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("suggest_replies", `{"replies":["Yes","No"]}`),
		toolTurn("suggest_replies", `{"replies":["Beach","Mountains"]}`),
		textTurn(""))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-qr-dup",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me something warm"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}
	// Server is pass-through; the client's whole-list replacement makes the
	// LAST event win (pinned client-side).
	got := suggestRepliesEvents(t, rec.Body.String())
	want := [][]string{{"Yes", "No"}, {"Beach", "Mountains"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("suggest_replies events = %v, want %v", got, want)
	}
}

func TestPlanSuggestRepliesCollapseToOneRejected(t *testing.T) {
	resetDB(t)
	// Two raw items pass the schema's minItems, but dedupe collapses them to
	// one — a lone chip would read as the app pre-answering, so nothing shows.
	fa := newFakeAnthropic(t,
		toolTurn("suggest_replies", `{"replies":["Yes, add it","Yes, add it "]}`),
		textTurn("Shall I add it?"))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-qr-one",
		Messages: []PlanChatMessage{{Role: "user", Content: "add the museum?"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}
	if evs := suggestRepliesEvents(t, rec.Body.String()); len(evs) != 0 {
		t.Fatalf("suggest_replies events = %v, want none when sanitization leaves <2", evs)
	}
	reqs := fa.requestBodies()
	if len(reqs) < 2 || !strings.Contains(string(reqs[1]), `"is_error":true`) {
		t.Fatal("follow-up request carries no is_error tool_result")
	}
}

func TestPlanSuggestRepliesRefusedAfterItinerary(t *testing.T) {
	resetDB(t)
	// The itinerary banner owns a turn that streamed `done` — a late
	// suggest_replies in the same turn is refused with no SSE event.
	fa := newFakeAnthropic(t,
		toolTurn("create_itinerary", `{"locations":[{"name":"Acropolis","latitude":37.97,"longitude":23.72,"day":1}],"summary":"A day in Athens"}`),
		toolTurn("suggest_replies", `{"replies":["Looks great","Change it"]}`),
		textTurn(""))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-qr-after-itinerary",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan athens"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}
	events := planEvents(t, rec.Body.String())
	if dones := eventsOfType(events, "done"); len(dones) != 1 {
		t.Fatalf("done events = %d, want 1", len(dones))
	}
	if evs := suggestRepliesEvents(t, rec.Body.String()); len(evs) != 0 {
		t.Fatalf("suggest_replies events = %v, want none after an itinerary", evs)
	}
	reqs := fa.requestBodies()
	if len(reqs) < 3 || !strings.Contains(string(reqs[2]), `"is_error":true`) {
		t.Fatal("suggest_replies after create_itinerary was not answered with is_error")
	}
}

func TestSanitizeQuickReplies(t *testing.T) {
	long := strings.Repeat("x", 81)
	got := sanitizeQuickReplies([]string{
		"  Mid-range budget ", "", "   ", long, "Mid-range budget", "Yes", "No", "Maybe", "Extra",
	})
	// Trimmed, empties/oversized/duplicates dropped, capped at 4.
	want := []string{"Mid-range budget", "Yes", "No", "Maybe"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sanitizeQuickReplies = %v, want %v", got, want)
	}
	if got := sanitizeQuickReplies([]string{"", "  "}); len(got) != 0 {
		t.Fatalf("all-invalid input sanitized to %v, want empty", got)
	}
}
