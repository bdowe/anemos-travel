package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

// Resumable plan conversations (specs/continue-where-you-left-off) end to end:
// the /plan persistence hook, the /chats REST surface, and the trip-graduation
// filter, all through buildRouter with the scriptable fake Anthropic.

// chatSessionRow reads the persisted session row for (userID, chatID) straight
// from the test DB; found is false when no row exists.
func chatSessionRow(t *testing.T, userID any, chatID string) (msgs []PlanChatMessage, title string, count int, found bool) {
	t.Helper()
	var raw []byte
	err := dbPool.QueryRow(context.Background(),
		`SELECT messages, title, message_count FROM plan_chat_sessions
		 WHERE user_id = $1 AND chat_id = $2`, userID, chatID).Scan(&raw, &title, &count)
	if err != nil {
		return nil, "", 0, false
	}
	if err := json.Unmarshal(raw, &msgs); err != nil {
		t.Fatalf("stored messages unparseable: %v", err)
	}
	return msgs, title, count, true
}

// (a) An authed text turn persists the session with both sides of the turn,
// and a follow-up turn updates the same row in place.
func TestPlanTurnPersistsChatSession(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t, textTurn("May is perfect for Lisbon."))
	user, token := createTestUser(t, "resumer@example.com")

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-resume-1",
		Messages: []PlanChatMessage{{Role: "user", Content: "where should I go in May?"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}

	msgs, title, count, found := chatSessionRow(t, user.ID, "chat-resume-1")
	if !found {
		t.Fatal("no chat session persisted for an authed turn")
	}
	if title != "where should I go in May?" {
		t.Fatalf("title = %q, want the opening message", title)
	}
	if count != 2 || len(msgs) != 2 {
		t.Fatalf("messages = %d (count %d), want 2 (user + assistant)", len(msgs), count)
	}
	if msgs[1].Role != "assistant" || msgs[1].Content != "May is perfect for Lisbon." {
		t.Fatalf("assistant message = %+v, want the streamed reply", msgs[1])
	}

	// Second turn: the client resends the grown history; same row, updated.
	newFakeAnthropic(t, textTurn("Three days is plenty."))
	rec = doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-resume-1",
		Messages: append(msgs,
			PlanChatMessage{Role: "user", Content: "how many days do I need?"}),
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("second /plan = %d, want 200", rec.Code)
	}
	msgs, title, count, found = chatSessionRow(t, user.ID, "chat-resume-1")
	if !found || count != 4 || len(msgs) != 4 {
		t.Fatalf("after second turn: found=%v messages=%d count=%d, want 4", found, len(msgs), count)
	}
	if title != "where should I go in May?" {
		t.Fatalf("title changed to %q; must stay the opening message", title)
	}
	var rows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM plan_chat_sessions WHERE user_id = $1`, user.ID).Scan(&rows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if rows != 1 {
		t.Fatalf("session rows = %d, want 1 (upsert, not insert)", rows)
	}
}

// (b) No persistence for anonymous turns, turns without a chat_id, or
// trip-bound refine turns.
func TestPlanTurnNotPersistedWhenAnonymousOrBound(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "ephemeral@example.com")
	trip := createTestTrip(t, user.ID, 1)

	newFakeAnthropic(t, textTurn("Anonymous answer."))
	doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-anon",
		Messages: []PlanChatMessage{{Role: "user", Content: "hi"}},
	})

	newFakeAnthropic(t, textTurn("No chat id answer."))
	doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		Messages: []PlanChatMessage{{Role: "user", Content: "hi"}},
	})

	newFakeAnthropic(t, toolTurn("update_itinerary_section",
		`{"scope":"trip","items":[{"name":"Cafe","latitude":1,"longitude":2,"day":1}]}`),
		textTurn("Updated."))
	doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-bound",
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "swap it all"}},
	})

	var rows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM plan_chat_sessions`).Scan(&rows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if rows != 0 {
		t.Fatalf("session rows = %d, want 0 (anonymous, no chat_id, trip-bound)", rows)
	}
}

// (c) A mid-turn model error still leaves the user's message (plus any partial
// streamed text) resumable — the whole point of the start-of-turn write.
func TestPlanErrorTurnStillPersistsUserMessage(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t, errorTurn("Overloaded"))
	user, token := createTestUser(t, "unlucky@example.com")

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-crashy",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me a week in Japan"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}

	msgs, _, _, found := chatSessionRow(t, user.ID, "chat-crashy")
	if !found {
		t.Fatal("session missing after mid-turn error")
	}
	if len(msgs) == 0 || msgs[0].Content != "plan me a week in Japan" {
		t.Fatalf("stored messages = %+v, want the user message first", msgs)
	}
}

// (d) The /chats surface: list shows resumable sessions, a saved trip with the
// same chat_id graduates the session out of the list, get returns the full
// transcript, delete dismisses, and other users' sessions are invisible.
func TestChatSessionsListGetDeleteAndGraduation(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "lister@example.com")
	_, otherToken := createTestUser(t, "other@example.com")

	// Two conversations: one stays in discussion, one produces a trip.
	newFakeAnthropic(t, textTurn("Talking about Portugal."))
	doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-discussing",
		Messages: []PlanChatMessage{{Role: "user", Content: "thinking about Portugal"}},
	})
	newFakeAnthropic(t,
		toolTurn("create_itinerary", `{
			"title":"Athens Weekend","summary":"Quick trip.",
			"locations":[{"name":"Acropolis","latitude":37.97,"longitude":23.72,"day":1,"city":"Athens","category":"attraction","time_of_day":"morning"}]}`),
		textTurn("Saved!"))
	doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-saved",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan Athens"}},
	})

	rec := doJSON(t, "GET", "/api/v1/chats", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /chats = %d: %s", rec.Code, rec.Body.String())
	}
	var list []ChatSessionSummaryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(list) != 1 || list[0].ChatID != "chat-discussing" {
		t.Fatalf("resumable list = %+v, want only chat-discussing (chat-saved graduated)", list)
	}
	if list[0].Preview != "Talking about Portugal." || list[0].MessageCount != 2 {
		t.Fatalf("summary = %+v, want preview of latest reply and count 2", list[0])
	}

	// Full transcript for resume.
	rec = doJSON(t, "GET", "/api/v1/chats/chat-discussing", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /chats/{id} = %d: %s", rec.Code, rec.Body.String())
	}
	var detail ChatSessionDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode detail: %v", err)
	}
	if len(detail.Messages) != 2 || detail.Messages[0].Role != "user" || detail.Messages[1].Role != "assistant" {
		t.Fatalf("detail messages = %+v, want ordered user+assistant pair", detail.Messages)
	}

	// Owner-scoped: another user sees nothing.
	if rec = doJSON(t, "GET", "/api/v1/chats/chat-discussing", otherToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("other user's GET = %d, want 404", rec.Code)
	}
	if rec = doJSON(t, "DELETE", "/api/v1/chats/chat-discussing", otherToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("other user's DELETE = %d, want 404", rec.Code)
	}

	// Dismiss.
	if rec = doJSON(t, "DELETE", "/api/v1/chats/chat-discussing", token, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE = %d, want 204: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "GET", "/api/v1/chats", token, nil)
	list = nil
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list after delete: %v", err)
	}
	if len(list) != 0 {
		t.Fatalf("list after dismiss = %+v, want empty", list)
	}

	// Settle async trip_created analytics before the next test truncates.
	waitForEventCount(t, user.ID, "trip_created", 1)
}

// (d2) Seed display labels: a machine-built opening message (near-me chip)
// carries a display_label that titles the session and round-trips through the
// transcript for chip re-rendering on resume — but never reaches the model.
func TestChatSessionTitleUsesDisplayLabel(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t, textTurn("You're in Lower East Side, NYC."))
	user, token := createTestUser(t, "nearme@example.com")

	const seedText = "My current location is latitude 40.7234, longitude -73.9938 (accuracy about 12 m). What's good to see, do, or eat near me right now?"
	const seedLabel = "Near my current location"
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-near-me",
		Messages: []PlanChatMessage{{
			Role: "user", Content: seedText, DisplayLabel: seedLabel,
		}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}

	msgs, title, _, found := chatSessionRow(t, user.ID, "chat-near-me")
	if !found {
		t.Fatal("no chat session persisted")
	}
	if title != seedLabel {
		t.Fatalf("title = %q, want the display label %q", title, seedLabel)
	}
	if len(msgs) == 0 || msgs[0].DisplayLabel != seedLabel || msgs[0].Content != seedText {
		t.Fatalf("stored first message = %+v, want label and content round-tripped", msgs[0])
	}

	// The resume surface returns the label so the client re-renders the chip.
	rec = doJSON(t, "GET", "/api/v1/chats/chat-near-me", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /chats/{id} = %d: %s", rec.Code, rec.Body.String())
	}
	var detail ChatSessionDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode detail: %v", err)
	}
	if len(detail.Messages) == 0 || detail.Messages[0].DisplayLabel != seedLabel {
		t.Fatalf("detail first message = %+v, want display_label present", detail.Messages[0])
	}

	// Metadata only: the label must never appear in any model-bound request.
	for i, body := range fa.requestBodies() {
		if bytes.Contains(body, []byte("display_label")) || bytes.Contains(body, []byte(seedLabel)) {
			t.Fatalf("model request %d leaked the display label: %s", i, body)
		}
	}
}

// (e) Compaction-aware persistence: when compaction runs, the stored session
// holds the compacted wire state (summary + kept tail), matching what the
// client resends after the `compacted` event — never the raw long history or
// a summary-as-message duplicate.
func TestChatSessionStoresCompactedState(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t, textTurn("Picking up where we left off."))
	fa.scriptNonStreamingTool(compactToolName, `{"summary":"- planning Portugal in May"}`)
	user, token := createTestUser(t, "compactor@example.com")

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-long",
		Messages: longPlanConversation(planCompactThreshold),
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}

	msgs, _, _, found := chatSessionRow(t, user.ID, "chat-long")
	if !found {
		t.Fatal("session missing after compacted turn")
	}
	wantLen := planCompactKeep + 1 // kept tail + this turn's assistant reply
	if len(msgs) != wantLen {
		t.Fatalf("stored messages = %d, want %d (compacted tail + reply)", len(msgs), wantLen)
	}
	var summary string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT summary FROM plan_chat_sessions WHERE user_id = $1 AND chat_id = $2`,
		user.ID, "chat-long").Scan(&summary); err != nil {
		t.Fatalf("summary query: %v", err)
	}
	if summary != "- planning Portugal in May" {
		t.Fatalf("stored summary = %q, want the compaction summary", summary)
	}
}
