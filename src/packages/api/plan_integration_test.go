package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// End-to-end /plan coverage through buildRouter, with the Anthropic API
// replaced by the scriptable fake (fake_anthropic_test.go). Each test drives
// a real SSE session — request validation, the agent tool loop, tool
// execution against the test DB, persistence, and the client-facing event
// stream — with zero external calls.

// planEvents parses every `data: {...}` SSE line the /plan handler wrote.
func planEvents(t *testing.T, body string) []map[string]any {
	t.Helper()
	var events []map[string]any
	for _, line := range strings.Split(body, "\n") {
		data, ok := strings.CutPrefix(line, "data: ")
		if !ok {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(data), &m); err != nil {
			t.Fatalf("unparseable SSE data line %q: %v", line, err)
		}
		events = append(events, m)
	}
	return events
}

func eventsOfType(events []map[string]any, typ string) []map[string]any {
	var out []map[string]any
	for _, e := range events {
		if e["type"] == typ {
			out = append(out, e)
		}
	}
	return out
}

// eventData returns the event's data payload as a map (nil if absent).
func eventData(e map[string]any) map[string]any {
	d, _ := e["data"].(map[string]any)
	return d
}

// joinedText reassembles the streamed answer from text_delta events.
func joinedText(events []map[string]any) string {
	var b strings.Builder
	for _, e := range eventsOfType(events, "text_delta") {
		if txt, ok := eventData(e)["text"].(string); ok {
			b.WriteString(txt)
		}
	}
	return b.String()
}

// (a) A text-only turn streams multiple deltas that reassemble to the full
// answer, with no error event — the plain conversational path.
func TestPlanTextTurnStreamsDeltas(t *testing.T) {
	resetDB(t)
	const answer = "Lisbon in May is lovely — shall I plan three days?"
	newFakeAnthropic(t, textTurn(answer))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-text",
		Messages: []PlanChatMessage{{Role: "user", Content: "where should I go in May?"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if deltas := eventsOfType(events, "text_delta"); len(deltas) < 2 {
		t.Fatalf("text_delta events = %d, want >= 2 (the fake splits text across frames)", len(deltas))
	}
	if got := joinedText(events); got != answer {
		t.Fatalf("reassembled text = %q, want %q", got, answer)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
}

// (b) Tool loop: the model requests the DB-backed get_trip tool, the handler
// executes it against the test DB, the tool_result round-trips to the model
// (asserted on the fake's second request body), and the final text streams.
func TestPlanToolLoopRoundTripsToolResult(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("get_trip", `{}`),
		textTurn("You have one saved trip: Test Trip."))

	user, token := createTestUser(t, "tool-loop@example.com")
	createTestTrip(t, user.ID, 2)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-tools",
		Messages: []PlanChatMessage{{Role: "user", Content: "what trips do I have saved?"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	calls := eventsOfType(events, "tool_call")
	if len(calls) != 1 || eventData(calls[0])["name"] != "get_trip" {
		t.Fatalf("tool_call events = %v, want exactly one get_trip", calls)
	}
	results := eventsOfType(events, "tool_result")
	if len(results) != 1 || eventData(results[0])["name"] != "get_trip" {
		t.Fatalf("tool_result events = %v, want exactly one get_trip", results)
	}
	if got := joinedText(events); got != "You have one saved trip: Test Trip." {
		t.Fatalf("final text = %q", got)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	// The second model request must carry the executed tool's result back —
	// including content that only exists in the database.
	reqs := fa.requestBodies()
	if len(reqs) != 2 {
		t.Fatalf("model requests = %d, want 2 (tool turn + follow-up)", len(reqs))
	}
	followUp := string(reqs[1])
	if !strings.Contains(followUp, `"tool_result"`) {
		t.Fatalf("follow-up request carries no tool_result block: %s", followUp)
	}
	if !strings.Contains(followUp, "Test Trip") {
		t.Fatalf("tool_result did not round-trip DB content (missing trip title): %s", followUp)
	}
}

// (b2) Working-indicator contract (specs/chat-working-indicator): every model
// call is preceded by a `thinking` frame, and a tool_use turn announces
// exactly one tool_call per block even though the announcement now happens at
// content_block_start — the execution loop must dedupe, or the client is left
// a stuck chip (one tool_result removes one list entry).
func TestPlanThinkingFramesAndEarlyToolAnnouncement(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		textThenToolTurn("Let me look that up.", "get_trip", `{}`),
		textTurn("You have one saved trip."))

	user, token := createTestUser(t, "thinking-frames@example.com")
	createTestTrip(t, user.ID, 2)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-thinking",
		Messages: []PlanChatMessage{{Role: "user", Content: "what trips do I have saved?"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	if thinks := eventsOfType(events, "thinking"); len(thinks) != 2 {
		t.Fatalf("thinking events = %d, want 2 (one per model call)", len(thinks))
	}
	calls := eventsOfType(events, "tool_call")
	if len(calls) != 1 || eventData(calls[0])["name"] != "get_trip" {
		t.Fatalf("tool_call events = %v, want exactly one get_trip (block-start announce + execution loop must dedupe)", calls)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
}

// (b3) An unknown tool name never reaches the wire as a tool_call — neither
// from the block-start announcement (registry-gated) nor from the execution
// loop (entry check now precedes the emit). No tool_result would ever clear
// such a chip, so it must not exist.
func TestPlanUnknownToolEmitsNoToolCall(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("imaginary_tool", `{}`),
		textTurn("Recovered without it."))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-unknown-tool",
		Messages: []PlanChatMessage{{Role: "user", Content: "hi"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if calls := eventsOfType(events, "tool_call"); len(calls) != 0 {
		t.Fatalf("tool_call events for unknown tool = %v, want none", calls)
	}
	if results := eventsOfType(events, "tool_result"); len(results) != 0 {
		t.Fatalf("tool_result events for unknown tool = %v, want none", results)
	}
}

// (c) create_itinerary end-to-end: the streamed `done` event carries a
// trip_id, and that trip — title, summary and items — is really persisted.
func TestPlanCreateItineraryPersistsTrip(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("create_itinerary", `{
			"title":"Athens Weekend","summary":"Two easy days in Athens.",
			"locations":[
				{"name":"Acropolis","latitude":37.9715,"longitude":23.7267,"day":1,"city":"Athens","category":"attraction","time_of_day":"morning"},
				{"name":"Ta Karamanlidika","latitude":37.9808,"longitude":23.7247,"day":1,"city":"Athens","category":"restaurant","time_of_day":"evening"}
			]}`),
		textTurn("Saved your Athens weekend!"))

	user, token := createTestUser(t, "finalizer@example.com")

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-athens",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me a weekend in Athens"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	dones := eventsOfType(events, "done")
	if len(dones) != 1 {
		t.Fatalf("done events = %d, want 1", len(dones))
	}
	done := eventData(dones[0])
	tripID, _ := done["trip_id"].(string)
	if tripID == "" {
		t.Fatalf("done event carries no trip_id: %v", done)
	}
	if locs, _ := done["locations"].([]any); len(locs) != 2 {
		t.Fatalf("done event locations = %v, want 2", done["locations"])
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	// The trip is readable through the normal REST surface.
	tripRec := doJSON(t, "GET", "/api/v1/trips/"+tripID, token, nil)
	if tripRec.Code != http.StatusOK {
		t.Fatalf("GET trip = %d: %s", tripRec.Code, tripRec.Body.String())
	}
	trip := decode(t, tripRec)
	if trip["title"] != "Athens Weekend" {
		t.Fatalf("persisted title = %v, want Athens Weekend", trip["title"])
	}
	items, _ := trip["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("persisted items = %d, want 2", len(items))
	}

	// Settle the async trip_created analytics before the next test truncates.
	waitForEventCount(t, user.ID, "trip_created", 1)
}

// set_travel_mode before create_itinerary: the session-recorded mode lands on
// the persisted trip, and the tools array offers set_travel_mode at the tail
// (cache-prefix regression guard).
func TestPlanSetTravelModePersistsWithItinerary(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("set_travel_mode", `{"mode":"car"}`),
		toolTurn("create_itinerary", `{
			"title":"Nantucket Drive","summary":"A driving trip to Nantucket.",
			"locations":[
				{"name":"Whaling Museum","latitude":41.2835,"longitude":-70.0995,"day":1,"city":"Nantucket","category":"attraction","time_of_day":"morning"}
			]}`),
		textTurn("Saved your Nantucket road trip!"))

	user, token := createTestUser(t, "driver@example.com")

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-nantucket",
		Messages: []PlanChatMessage{{Role: "user", Content: "we're driving to Nantucket"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	dones := eventsOfType(events, "done")
	if len(dones) != 1 {
		t.Fatalf("done events = %d, want 1", len(dones))
	}
	tripID, _ := eventData(dones[0])["trip_id"].(string)
	if tripID == "" {
		t.Fatal("done event carries no trip_id")
	}

	tripRec := doJSON(t, "GET", "/api/v1/trips/"+tripID, token, nil)
	if tripRec.Code != http.StatusOK {
		t.Fatalf("GET trip = %d: %s", tripRec.Code, tripRec.Body.String())
	}
	if trip := decode(t, tripRec); trip["travel_mode"] != "car" {
		t.Fatalf("persisted travel_mode = %v, want car", trip["travel_mode"])
	}

	// Registry-tail guard: the tools array offered to the model must end with
	// suggest_replies — new tools may only append (prompt-cache prefix rule).
	reqs := fa.requestBodies()
	if len(reqs) == 0 {
		t.Fatal("no model requests recorded")
	}
	var body struct {
		Tools []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(reqs[0], &body); err != nil {
		t.Fatalf("unmarshal request body: %v", err)
	}
	// search_hotels is the newest tail append (specs/hotel-search) and is
	// ungated, so it is last in every session shape.
	if n := len(body.Tools); n == 0 || body.Tools[n-1].Name != "search_hotels" {
		t.Fatalf("tools tail = %+v, want search_hotels last", body.Tools)
	}

	waitForEventCount(t, user.ID, "trip_created", 1)
}

// (c, trip-bound) update_itinerary_section on a bound trip replaces the
// section in the DB and streams a trip_updated event with the trip's id.
func TestPlanBoundSessionUpdatesSectionAndStreamsTripUpdated(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("update_itinerary_section", `{"scope":"trip","items":[{"name":"New Cafe","latitude":37.98,"longitude":23.74,"day":1}]}`),
		textTurn("Swapped the whole plan for the cafe."))

	user, token := createTestUser(t, "refiner@example.com")
	trip := createTestTrip(t, user.ID, 2)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "replace everything with one cafe"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 || eventData(updated[0])["trip_id"] != trip.ID.String() {
		t.Fatalf("trip_updated events = %v, want exactly one for trip %s", updated, trip.ID)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	// A bound session must never create a new trip version.
	if dones := eventsOfType(events, "done"); len(dones) != 0 {
		t.Fatalf("unexpected done events on a bound session: %v", dones)
	}

	var count int
	var name string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*), min(name) FROM itinerary_items WHERE trip_id = $1`,
		trip.ID).Scan(&count, &name); err != nil {
		t.Fatalf("items query: %v", err)
	}
	if count != 1 || name != "New Cafe" {
		t.Fatalf("items after update = %d/%q, want 1/\"New Cafe\"", count, name)
	}
}

// remove_booking_todo end-to-end: the model reads the checklist via get_trip
// (which must expose todo ids), removes the stale item, and the client gets a
// trip_updated event so the trip page refreshes.
func TestPlanRemoveBookingTodoStreamsTripUpdated(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "checklist@example.com")
	trip := createTestTrip(t, user.ID, 1)
	seedSession, _ := testPlanSession(true, user.ID)
	todoID := seedAgentTodo(t, seedSession, trip.ID, "Book flights EWR to CUR")

	fa := newFakeAnthropic(t,
		toolTurn("get_trip", `{"trip_id":"`+trip.ID.String()+`"}`),
		toolTurn("remove_booking_todo", `{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`"}`),
		textTurn("Cleared the old Curaçao flight to-do."))

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "we're going to Miami now, fix the checklist"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	if results := eventsOfType(events, "tool_result"); len(results) != 2 {
		t.Fatalf("tool_result events = %d, want 2 (get_trip + remove)", len(results))
	}
	// get_trip's tool_result (round-tripped to the model in request 2) must
	// expose the todo id the model then used.
	reqs := fa.requestBodies()
	if len(reqs) != 3 {
		t.Fatalf("model requests = %d, want 3", len(reqs))
	}
	if !strings.Contains(string(reqs[1]), todoID.String()) {
		t.Fatalf("get_trip result did not carry the todo id back to the model: %s", reqs[1])
	}

	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 || eventData(updated[0])["trip_id"] != trip.ID.String() {
		t.Fatalf("trip_updated events = %v, want exactly one for trip %s", updated, trip.ID)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	var count int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM booking_todos WHERE trip_id = $1`, trip.ID).Scan(&count); err != nil {
		t.Fatalf("todos query: %v", err)
	}
	if count != 0 {
		t.Fatalf("booking todos after remove = %d, want 0", count)
	}
}

// (d) A mid-turn model error (SSE `error` event after deltas already
// streamed) surfaces to the client as a /plan error event, not a hang or a
// silent truncation.
func TestPlanMidTurnModelErrorSurfaces(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t, errorTurn("Overloaded"))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-err",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan something"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200 (headers are sent before the model call)", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	// The pre-error delta proves the failure hit MID-turn.
	if deltas := eventsOfType(events, "text_delta"); len(deltas) == 0 {
		t.Fatal("no text_delta before the error; the error was not mid-turn")
	}
	errs := eventsOfType(events, "error")
	if len(errs) != 1 {
		t.Fatalf("error events = %d, want 1", len(errs))
	}
	if msg, _ := eventData(errs[0])["message"].(string); msg == "" {
		t.Fatalf("error event carries no message: %v", errs[0])
	}
	if dones := eventsOfType(events, "done"); len(dones) != 0 {
		t.Fatalf("unexpected done events after error: %v", dones)
	}
}

// check_flight_connectivity end-to-end: the tool executes against the fake
// Duffel, its compact summary round-trips to the model, and — unlike
// search_flights — nothing is streamed as a `flights` card.
func TestPlanConnectivityToolLoop(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("check_flight_connectivity",
			`{"origin":"SJU","candidates":["BDA","NAS"],"depart_date":"2026-09-15","onward_destination":"BTV"}`),
		textTurn("Nassau is the far better stopover — Bermuda routes are long and pricey."))

	cs := &connStub{offers: map[string]string{
		"SJU-BDA": offersBody(connOffer("i1", "1450.00", "USD", "PT12H05M", 2)),
		"BDA-BTV": offersBody(connOffer("i2", "388.00", "USD", "PT9H40M", 1)),
		"SJU-NAS": offersBody(connOffer("i3", "210.00", "USD", "PT3H30M", 0)),
		"NAS-BTV": offersBody(connOffer("i4", "305.00", "USD", "PT7H10M", 1)),
	}}
	swapConnStub(t, cs)

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-connectivity",
		Messages: []PlanChatMessage{{Role: "user", Content: "any island stopover between San Andrés and Burlington?"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	calls := eventsOfType(events, "tool_call")
	if len(calls) != 1 || eventData(calls[0])["name"] != "check_flight_connectivity" {
		t.Fatalf("tool_call events = %v, want one check_flight_connectivity", calls)
	}
	results := eventsOfType(events, "tool_result")
	if len(results) != 1 || eventData(results[0])["name"] != "check_flight_connectivity" {
		t.Fatalf("tool_result events = %v, want one check_flight_connectivity", results)
	}
	if flights := eventsOfType(events, "flights"); len(flights) != 0 {
		t.Fatalf("connectivity check must not stream flight cards: %v", flights)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	if got := joinedText(events); !strings.Contains(got, "Nassau") {
		t.Fatalf("final text = %q", got)
	}

	// The model's follow-up request must carry the real comparison numbers.
	reqs := fa.requestBodies()
	if len(reqs) != 2 {
		t.Fatalf("model requests = %d, want 2", len(reqs))
	}
	followUp := string(reqs[1])
	for _, want := range []string{`"tool_result"`, "from USD 210", "timed out", "Connectivity check from SJU"} {
		if want == "timed out" {
			if strings.Contains(followUp, want) {
				t.Fatalf("no leg should have timed out: %s", followUp)
			}
			continue
		}
		if !strings.Contains(followUp, want) {
			t.Fatalf("follow-up request missing %q: %s", want, followUp)
		}
	}
}

// (e) The local-ingest anti-hallucination gate: extraction (a NON-streaming
// forced-tool call through the same seam) drafts a pin, Google verification
// cannot fill coordinates (no Places key), and publish is refused while the
// draft has no coordinates.
func TestLocalIngestUnverifiedDraftCannotPublish(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t)
	fa.scriptNonStreamingTool("draft_local_content",
		`{"recommendations":[{"name":"To Steki","category":"restaurant","neighborhood":"Psyrri","tip":"Go before 8pm","quote":"","tags":["food"],"search_hint":"To Steki taverna, Athens"}]}`)

	// Force the verify step to fail: the Places singleton captured its key at
	// process init, so blank it directly (integration tests never run parallel).
	oldKey := placesService.APIKey
	placesService.APIKey = ""
	t.Cleanup(func() { placesService.APIKey = oldKey })

	admin, adminToken := createTestUser(t, "curator@example.com")
	makeAdmin(t, admin.ID)

	srcRec := doJSON(t, "POST", "/api/v1/admin/local/sources", adminToken,
		map[string]any{"name": "Maria", "location": "Athens"})
	if srcRec.Code != http.StatusCreated {
		t.Fatalf("create source = %d: %s", srcRec.Code, srcRec.Body.String())
	}
	sourceID, _ := decode(t, srcRec)["id"].(string)

	ingRec := doJSON(t, "POST", "/api/v1/admin/local/ingest", adminToken, map[string]any{
		"source_id": sourceID,
		"city":      "Athens",
		"kind":      "notes",
		"raw_text":  "Maria says To Steki in Psyrri is the move, go before 8pm.",
	})
	if ingRec.Code != http.StatusCreated {
		t.Fatalf("ingest = %d: %s", ingRec.Code, ingRec.Body.String())
	}
	var ing struct {
		Recommendations []struct {
			ID            uuid.UUID `json:"id"`
			Status        string    `json:"status"`
			Latitude      *float64  `json:"latitude"`
			PlaceVerified bool      `json:"place_verified"`
		} `json:"recommendations"`
		Verified   int `json:"verified"`
		Unverified int `json:"unverified"`
	}
	if err := json.Unmarshal(ingRec.Body.Bytes(), &ing); err != nil {
		t.Fatalf("decode ingest response: %v", err)
	}
	if len(ing.Recommendations) != 1 || ing.Verified != 0 || ing.Unverified != 1 {
		t.Fatalf("ingest = %d recs / %d verified / %d unverified, want 1/0/1: %s",
			len(ing.Recommendations), ing.Verified, ing.Unverified, ingRec.Body.String())
	}
	draft := ing.Recommendations[0]
	if draft.Status != "draft" || draft.Latitude != nil || draft.PlaceVerified {
		t.Fatalf("draft = %+v, want unverified draft with nil coordinates", draft)
	}

	// The gate: a coordinate-less draft cannot be published.
	pubRec := doJSON(t, "POST", "/api/v1/admin/local/recommendations/"+draft.ID.String()+"/publish", adminToken, nil)
	if pubRec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("publish unverified draft = %d, want 422: %s", pubRec.Code, pubRec.Body.String())
	}
	if body := pubRec.Body.String(); !strings.Contains(body, "not verified") {
		t.Fatalf("publish rejection reason = %s, want the not-verified message", body)
	}

	// Still a draft afterwards — the gate blocked, it didn't archive or mutate.
	var status string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT status FROM local_recommendations WHERE id = $1`, draft.ID).Scan(&status); err != nil {
		t.Fatalf("status query: %v", err)
	}
	if status != "draft" {
		t.Fatalf("status after blocked publish = %q, want draft", status)
	}
}

// anthropicRequests splits the fake's captured bodies into (nonStreaming,
// streaming) parsed request payloads, in arrival order.
func anthropicRequests(t *testing.T, fa *fakeAnthropic) (nonStreaming, streaming []map[string]any) {
	t.Helper()
	for _, body := range fa.requestBodies() {
		var m map[string]any
		if err := json.Unmarshal(body, &m); err != nil {
			t.Fatalf("unparseable fake-anthropic request: %v", err)
		}
		if s, _ := m["stream"].(bool); s {
			streaming = append(streaming, m)
		} else {
			nonStreaming = append(nonStreaming, m)
		}
	}
	return nonStreaming, streaming
}

// firstMessageText extracts the text of the first message in a parsed
// /v1/messages request body (string or single-text-block content).
func firstMessageText(t *testing.T, req map[string]any) string {
	t.Helper()
	msgs, _ := req["messages"].([]any)
	if len(msgs) == 0 {
		t.Fatal("request has no messages")
	}
	m, _ := msgs[0].(map[string]any)
	switch c := m["content"].(type) {
	case string:
		return c
	case []any:
		if len(c) > 0 {
			if block, ok := c[0].(map[string]any); ok {
				if txt, ok := block["text"].(string); ok {
					return txt
				}
			}
		}
	}
	t.Fatalf("first message has no text content: %v", m)
	return ""
}

func longPlanConversation(n int) []PlanChatMessage {
	msgs := make([]PlanChatMessage, n)
	for i := range msgs {
		role, text := "user", fmt.Sprintf("user turn %d", i)
		if i%2 == 1 {
			role, text = "assistant", fmt.Sprintf("assistant turn %d", i)
		}
		msgs[i] = PlanChatMessage{Role: role, Content: text}
	}
	return msgs
}

// (f) Compaction: a history at the threshold gets summarized before the turn.
// The stream carries `compacting` then `compacted` (summary + how many wire
// messages it folded), and the model sees [summary message + kept tail], not
// the full history.
func TestPlanCompactsLongConversation(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t, textTurn("Got it — picking up where we left off."))
	fa.scriptNonStreamingTool(compactToolName, `{"summary":"- travelers: 3, one vegetarian\n- dates: 2026-07-23 to 2026-07-30"}`)

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:   "chat-compact",
		Messages: longPlanConversation(planCompactThreshold),
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	if got := len(eventsOfType(events, "compacting")); got != 1 {
		t.Fatalf("compacting events = %d, want 1", got)
	}
	compacted := eventsOfType(events, "compacted")
	if len(compacted) != 1 {
		t.Fatalf("compacted events = %d, want 1", len(compacted))
	}
	data := eventData(compacted[0])
	if s, _ := data["summary"].(string); !strings.Contains(s, "travelers: 3") {
		t.Fatalf("compacted summary = %v", data["summary"])
	}
	wantThrough := float64(planCompactThreshold - planCompactKeep)
	if data["through_index"] != wantThrough {
		t.Fatalf("through_index = %v, want %v", data["through_index"], wantThrough)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	nonStreaming, streaming := anthropicRequests(t, fa)
	if len(nonStreaming) != 1 || len(streaming) != 1 {
		t.Fatalf("model requests = %d non-streaming / %d streaming, want 1/1", len(nonStreaming), len(streaming))
	}
	msgs, _ := streaming[0]["messages"].([]any)
	if len(msgs) != 1+planCompactKeep {
		t.Fatalf("streamed request messages = %d, want %d (summary + keep window)", len(msgs), 1+planCompactKeep)
	}
	first := firstMessageText(t, streaming[0])
	if !strings.HasPrefix(first, "Summary of the conversation so far") || !strings.Contains(first, "travelers: 3") {
		t.Fatalf("first streamed message is not the summary: %q", first)
	}
}

// (g) Compaction failure is invisible: when the summarizer returns no tool
// call (the fake's default non-streaming answer), the turn proceeds on the
// full history with no error and no compacted event.
func TestPlanCompactionFailureFallsBackToFullHistory(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t, textTurn("Continuing without compaction."))

	msgs := longPlanConversation(planCompactThreshold)
	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{ChatID: "chat-compact-fail", Messages: msgs})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())

	if got := len(eventsOfType(events, "compacted")); got != 0 {
		t.Fatalf("compacted events = %d, want 0 on summarizer failure", got)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("compaction failure must not surface an error: %v", errs)
	}
	if got := joinedText(events); got != "Continuing without compaction." {
		t.Fatalf("final text = %q", got)
	}

	_, streaming := anthropicRequests(t, fa)
	if len(streaming) != 1 {
		t.Fatalf("streaming requests = %d, want 1", len(streaming))
	}
	if got, _ := streaming[0]["messages"].([]any); len(got) != len(msgs) {
		t.Fatalf("streamed request messages = %d, want the full %d on fallback", len(got), len(msgs))
	}
}

// (h) A client-held summary below the threshold is prepended as established
// context with no summarizer call.
func TestPlanSummaryPrependedBelowThreshold(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t, textTurn("Right — three of you, one vegetarian."))

	rec := doJSON(t, "POST", "/api/v1/plan", "", PlanRequest{
		ChatID:  "chat-summary",
		Summary: "- travelers: 3, one vegetarian",
		Messages: []PlanChatMessage{
			{Role: "user", Content: "remind me of our group's constraints"},
		},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if got := len(eventsOfType(events, "compacting")); got != 0 {
		t.Fatalf("compacting events = %d, want 0 below threshold", got)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	nonStreaming, streaming := anthropicRequests(t, fa)
	if len(nonStreaming) != 0 || len(streaming) != 1 {
		t.Fatalf("model requests = %d non-streaming / %d streaming, want 0/1", len(nonStreaming), len(streaming))
	}
	msgs, _ := streaming[0]["messages"].([]any)
	if len(msgs) != 2 {
		t.Fatalf("streamed request messages = %d, want 2 (summary + user turn)", len(msgs))
	}
	first := firstMessageText(t, streaming[0])
	if !strings.HasPrefix(first, "Summary of the conversation so far") || !strings.Contains(first, "one vegetarian") {
		t.Fatalf("first streamed message is not the summary: %q", first)
	}
}

// The exact wire shape the Dart client emits (plan_service.dart builds the
// top-level object; plan_provider.dart builds each message map), pinned as
// raw hand-written JSON. Every other /plan test round-trips the server's own
// PlanRequest struct, which can never catch client/server field-name or
// nesting drift — this one can (2026-08-12 prod incident postmortem gap).
func TestPlanWireShapeFromDartClient(t *testing.T) {
	resetDB(t)

	postRaw := func(t *testing.T, raw, token string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest("POST", "/api/v1/plan", strings.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Forwarded-For", nextTestIP())
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		testRouter.ServeHTTP(rec, req)
		return rec
	}

	assertCleanStream := func(t *testing.T, rec *httptest.ResponseRecorder, answer string) {
		t.Helper()
		if rec.Code != http.StatusOK {
			t.Fatalf("/plan = %d, want 200", rec.Code)
		}
		events := planEvents(t, rec.Body.String())
		if errs := eventsOfType(events, "error"); len(errs) != 0 {
			t.Fatalf("stream has error events: %v", errs)
		}
		if got := joinedText(events); got != answer {
			t.Fatalf("streamed text = %q, want %q", got, answer)
		}
	}

	t.Run("anonymous chat with display_label", func(t *testing.T) {
		const answer = "Athens it is."
		newFakeAnthropic(t, textTurn(answer))
		raw := `{"messages":[{"role":"user","content":"plan a day in Athens","display_label":"Near me: 37.9838, 23.7275"}],"chat_id":"` + uuid.NewString() + `"}`
		assertCleanStream(t, postRaw(t, raw, ""), answer)
	})

	t.Run("authed trip-bound refine", func(t *testing.T) {
		u, token := createTestUser(t, "wire-shape@example.com")
		trip := createTestTrip(t, u.ID, 2)
		const answer = "Day 2 relaxed."
		newFakeAnthropic(t, textTurn(answer))
		raw := fmt.Sprintf(`{"messages":[{"role":"user","content":"make day 2 more relaxed"}],"chat_id":%q,"trip_id":%q}`,
			uuid.NewString(), trip.ID.String())
		assertCleanStream(t, postRaw(t, raw, token), answer)
	})

	t.Run("chat with image attachment", func(t *testing.T) {
		const answer = "That looks like the Acropolis."
		newFakeAnthropic(t, textTurn(answer))
		// 1x1 transparent PNG, base64 without a data: URI prefix — exactly how
		// plan_provider.dart serializes attachment bytes.
		raw := `{"messages":[{"role":"user","content":"where is this?","images":[{"media_type":"image/png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="}]}],"chat_id":"` + uuid.NewString() + `"}`
		assertCleanStream(t, postRaw(t, raw, ""), answer)
	})
}
