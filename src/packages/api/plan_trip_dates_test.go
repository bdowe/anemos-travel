package main

// set_trip_dates (specs/set-trip-dates): the whole-trip date shift. The unit
// table covers the pure end/delta derivation; the DB tests assert the one-tx
// cascade across trips + accommodations + trip_segments + booking_todos, the
// no-anchor and validation paths, and every rung of the target-trip
// resolution ladder (bound, same-request persisted, chat lineage).

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

func civilDate(s string) time.Time {
	t, err := time.Parse(dateLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

func validDate(s string) pgtype.Date {
	return pgtype.Date{Time: civilDate(s), Valid: true}
}

func TestComputeTripDateShift(t *testing.T) {
	newEnd := func(s string) *time.Time { d := civilDate(s); return &d }
	cases := []struct {
		name      string
		oldStart  pgtype.Date
		oldEnd    pgtype.Date
		newStart  string
		newEnd    *time.Time
		maxDay    int
		wantEnd   string
		wantDelta int
		wantAnch  bool
		wantErr   bool
	}{
		{"shift +7 preserves duration", validDate("2026-06-01"), validDate("2026-06-05"), "2026-06-08", nil, 1, "2026-06-12", 7, true, false},
		{"shift -3 preserves duration", validDate("2026-06-10"), validDate("2026-06-14"), "2026-06-07", nil, 1, "2026-06-11", -3, true, false},
		{"explicit end changes length", validDate("2026-06-01"), validDate("2026-06-05"), "2026-06-08", newEnd("2026-06-20"), 1, "2026-06-20", 7, true, false},
		{"end before start errors", validDate("2026-06-01"), validDate("2026-06-05"), "2026-06-08", newEnd("2026-06-01"), 1, "", 0, false, true},
		{"no anchor derives from maxDay", pgtype.Date{}, pgtype.Date{}, "2026-06-08", nil, 4, "2026-06-11", 0, false, false},
		{"no anchor empty itinerary", pgtype.Date{}, pgtype.Date{}, "2026-06-08", nil, 0, "2026-06-08", 0, false, false},
		{"start without end derives from maxDay", validDate("2026-06-01"), pgtype.Date{}, "2026-06-08", nil, 3, "2026-06-10", 7, true, false},
		{"same start is delta zero", validDate("2026-06-01"), validDate("2026-06-05"), "2026-06-01", newEnd("2026-06-09"), 1, "2026-06-09", 0, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			end, delta, anchored, err := computeTripDateShift(tc.oldStart, tc.oldEnd, civilDate(tc.newStart), tc.newEnd, tc.maxDay)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("want error, got end=%s delta=%d", end.Format(dateLayout), delta)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got := end.Format(dateLayout); got != tc.wantEnd {
				t.Fatalf("end = %s, want %s", got, tc.wantEnd)
			}
			if delta != tc.wantDelta {
				t.Fatalf("delta = %d, want %d", delta, tc.wantDelta)
			}
			if anchored != tc.wantAnch {
				t.Fatalf("hadAnchor = %v, want %v", anchored, tc.wantAnch)
			}
		})
	}
}

// seedDatedTrip gives the trip dates plus one fully dated + one partially
// dated child in each table, so the cascade and its NULL handling are both
// observable.
func seedDatedTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-06-01"), EndDate: validDate("2026-06-05"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Dated Hotel",
		CheckIn: validDate("2026-06-01"), CheckOut: validDate("2026-06-03"),
	}); err != nil {
		t.Fatalf("seed accommodation: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Undated Hotel",
	}); err != nil {
		t.Fatalf("seed undated accommodation: %v", err)
	}
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "train",
		DepartDate: validDate("2026-06-03"), ArriveDate: validDate("2026-06-03"),
	}); err != nil {
		t.Fatalf("seed segment: %v", err)
	}
	if _, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: trip.ID, Kind: "flight", TodoKey: "seed:flight", Title: "Book flights",
		DepartDate: validDate("2026-06-01"), ReturnDate: validDate("2026-06-05"), Position: 1,
	}); err != nil {
		t.Fatalf("seed todo: %v", err)
	}
	if _, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: trip.ID, Kind: "stay", TodoKey: "seed:stay", Title: "Undated todo", Position: 2,
	}); err != nil {
		t.Fatalf("seed undated todo: %v", err)
	}
}

func tripDates(t *testing.T, tripID uuid.UUID) (string, string) {
	t.Helper()
	var start, end *time.Time
	if err := dbPool.QueryRow(context.Background(),
		`SELECT start_date, end_date FROM trips WHERE id = $1`, tripID).Scan(&start, &end); err != nil {
		t.Fatalf("trip dates query: %v", err)
	}
	fmtDate := func(d *time.Time) string {
		if d == nil {
			return ""
		}
		return d.Format(dateLayout)
	}
	return fmtDate(start), fmtDate(end)
}

// scanDates returns the formatted values of a two-date-column query, with ""
// for NULLs.
func scanDates(t *testing.T, query string, tripID uuid.UUID, extra ...any) (string, string) {
	t.Helper()
	var a, b *time.Time
	args := append([]any{tripID}, extra...)
	if err := dbPool.QueryRow(context.Background(), query, args...).Scan(&a, &b); err != nil {
		t.Fatalf("scanDates(%s): %v", query, err)
	}
	f := func(d *time.Time) string {
		if d == nil {
			return ""
		}
		return d.Format(dateLayout)
	}
	return f(a), f(b)
}

// The headline path: a bound refine session shifts the trip a week later and
// every dated child moves with it, in one turn, with a trip_updated event.
func TestPlanSetTripDatesShiftsWholeTrip(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("set_trip_dates", `{"start_date":"2026-06-08"}`),
		textTurn("Moved the whole trip a week later."))

	user, token := createTestUser(t, "shifter@example.com")
	trip := createTestTrip(t, user.ID, 1)
	seedDatedTrip(t, trip, user.ID)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "shift my trip one week later"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 || eventData(updated[0])["trip_id"] != trip.ID.String() {
		t.Fatalf("trip_updated events = %v, want exactly one for trip %s", updated, trip.ID)
	}

	// The model-facing result narrates the shift and the rebooking caveat.
	// SSE tool_result events carry only the tool name; the text rides the
	// follow-up model request as a tool_result block.
	reqs := fa.requestBodies()
	if len(reqs) < 2 {
		t.Fatalf("model requests = %d, want >= 2 (tool round-trip)", len(reqs))
	}
	followUp := string(reqs[1])
	for _, want := range []string{"2026-06-08 to 2026-06-12", "7 day(s) later", "1 stay(s)", "1 transport leg(s)", "1 booking to-do(s)", "ORIGINAL dates"} {
		if !strings.Contains(followUp, want) {
			t.Fatalf("tool_result round-trip missing %q:\n%s", want, followUp)
		}
	}

	if start, end := tripDates(t, trip.ID); start != "2026-06-08" || end != "2026-06-12" {
		t.Fatalf("trip dates = %s/%s, want 2026-06-08/2026-06-12", start, end)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Dated Hotel"); in != "2026-06-08" || out != "2026-06-10" {
		t.Fatalf("dated stay = %s/%s, want 2026-06-08/2026-06-10", in, out)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Undated Hotel"); in != "" || out != "" {
		t.Fatalf("undated stay gained dates: %s/%s", in, out)
	}
	if dep, arr := scanDates(t, `SELECT depart_date, arrive_date FROM trip_segments WHERE trip_id = $1`, trip.ID); dep != "2026-06-10" || arr != "2026-06-10" {
		t.Fatalf("segment = %s/%s, want 2026-06-10/2026-06-10", dep, arr)
	}
	if dep, ret := scanDates(t, `SELECT depart_date, return_date FROM booking_todos WHERE trip_id = $1 AND todo_key = $2`, trip.ID, "seed:flight"); dep != "2026-06-08" || ret != "2026-06-12" {
		t.Fatalf("dated todo = %s/%s, want 2026-06-08/2026-06-12", dep, ret)
	}
	if dep, ret := scanDates(t, `SELECT depart_date, return_date FROM booking_todos WHERE trip_id = $1 AND todo_key = $2`, trip.ID, "seed:stay"); dep != "" || ret != "" {
		t.Fatalf("undated todo gained dates: %s/%s", dep, ret)
	}

	waitForEventCount(t, user.ID, "agent_trip_dates_set", 1)
}

// A previously dateless trip gets dates set without any child rows moving.
func TestPlanSetTripDatesNoAnchorLeavesChildren(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("set_trip_dates", `{"start_date":"2026-06-08","end_date":"2026-06-10"}`),
		textTurn("Dates set."))

	user, token := createTestUser(t, "dateless@example.com")
	trip := createTestTrip(t, user.ID, 1)
	// A dated child on a dateless trip: absolute dates with no anchor.
	if _, err := store.New(dbPool).CreateAccommodation(context.Background(), store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Fixed Hotel",
		CheckIn: validDate("2026-07-01"), CheckOut: validDate("2026-07-03"),
	}); err != nil {
		t.Fatalf("seed accommodation: %v", err)
	}

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "we go june 8-10"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	if start, end := tripDates(t, trip.ID); start != "2026-06-08" || end != "2026-06-10" {
		t.Fatalf("trip dates = %s/%s, want 2026-06-08/2026-06-10", start, end)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1`, trip.ID); in != "2026-07-01" || out != "2026-07-03" {
		t.Fatalf("no-anchor set moved a child: %s/%s, want 2026-07-01/2026-07-03", in, out)
	}
	reqs := fa.requestBodies()
	if len(reqs) < 2 {
		t.Fatalf("model requests = %d, want >= 2 (tool round-trip)", len(reqs))
	}
	if followUp := string(reqs[1]); !strings.Contains(followUp, "had no dates before") {
		t.Fatalf("tool_result round-trip missing the no-anchor explanation:\n%s", followUp)
	}
}

// Invalid input is a tool error, and nothing in the DB changes.
func TestPlanSetTripDatesValidationLeavesDBUntouched(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("set_trip_dates", `{"start_date":"2026-06-08","end_date":"2026-06-01"}`),
		toolTurn("set_trip_dates", `{"start_date":"June 8th"}`),
		textTurn("Could not update the dates."))

	user, token := createTestUser(t, "invalid@example.com")
	trip := createTestTrip(t, user.ID, 1)
	seedDatedTrip(t, trip, user.ID)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "move the trip"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if updated := eventsOfType(events, "trip_updated"); len(updated) != 0 {
		t.Fatalf("unexpected trip_updated on validation failure: %v", updated)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-06-01" || end != "2026-06-05" {
		t.Fatalf("trip dates changed on invalid input: %s/%s", start, end)
	}
	if in, _ := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Dated Hotel"); in != "2026-06-01" {
		t.Fatalf("stay moved on invalid input: %s", in)
	}
}

// Fresh chat, same request: create_itinerary persists the trip, then a date
// change in the same turn resolves it via s.tripID — no new trip version.
func TestPlanSetTripDatesFreshChatSameTurn(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		// end_date is explicit because create_itinerary now refuses a write that
		// dates one end and not the other (plan_spine.go): a spine's highest day
		// number is its final city's ARRIVAL, so deriving the end from it saves
		// the trip short. 2026-06-02 is exactly what the old derivation produced
		// from this day span, so everything downstream is unchanged.
		toolTurn("create_itinerary", `{"title":"Athens Weekend","start_date":"2026-06-01","end_date":"2026-06-02","locations":[{"name":"Acropolis","latitude":37.97,"longitude":23.72,"day":1},{"name":"Plaka","latitude":37.972,"longitude":23.73,"day":2}]}`),
		toolTurn("set_trip_dates", `{"start_date":"2026-06-08"}`),
		textTurn("Saved and re-dated."))

	user, token := createTestUser(t, "freshchat@example.com")
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-fresh-same",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan athens june 1, actually june 8"}},
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
	tid, err := uuid.Parse(tripID)
	if err != nil {
		t.Fatalf("done trip_id = %q: %v", tripID, err)
	}

	// end derives from the old duration (create_itinerary set 2026-06-01 to
	// 2026-06-02 from day span 2).
	if start, end := tripDates(t, tid); start != "2026-06-08" || end != "2026-06-09" {
		t.Fatalf("trip dates = %s/%s, want 2026-06-08/2026-06-09", start, end)
	}
	// The shift must not have created a second trip version.
	var trips int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trips WHERE user_id = $1`, user.ID).Scan(&trips); err != nil {
		t.Fatalf("trips count: %v", err)
	}
	if trips != 1 {
		t.Fatalf("trips = %d, want 1 (set_trip_dates must never create a version)", trips)
	}
}

// Fresh chat, NEXT turn: a later /plan request in the same conversation has
// no bound trip and no s.tripID — the chat lineage resolves the target.
func TestPlanSetTripDatesFreshChatNextTurnLineage(t *testing.T) {
	resetDB(t)
	// The fake keys turn selection off tool_result count, so a second /plan
	// request would replay turn 0 — script each request with its own fake.
	newFakeAnthropic(t,
		// Explicit end_date, same reason as above; 2026-06-01 is what the old
		// day-span derivation produced for this one-day itinerary.
		toolTurn("create_itinerary", `{"title":"Athens Weekend","start_date":"2026-06-01","end_date":"2026-06-01","locations":[{"name":"Acropolis","latitude":37.97,"longitude":23.72,"day":1}]}`),
		textTurn("Saved!"))

	user, token := createTestUser(t, "lineage@example.com")
	first := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-lineage",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan athens june 1"}},
	})
	if first.Code != http.StatusOK {
		t.Fatalf("first /plan = %d, want 200", first.Code)
	}

	newFakeAnthropic(t,
		toolTurn("set_trip_dates", `{"start_date":"2026-06-15"}`),
		textTurn("Moved it."))
	second := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-lineage",
		Messages: []PlanChatMessage{
			{Role: "user", Content: "plan athens june 1"},
			{Role: "assistant", Content: "Saved!"},
			{Role: "user", Content: "actually shift it to june 15"},
		},
	})
	if second.Code != http.StatusOK {
		t.Fatalf("second /plan = %d, want 200", second.Code)
	}
	events := planEvents(t, second.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 {
		t.Fatalf("trip_updated events = %d, want 1", len(updated))
	}
	tid, err := uuid.Parse(eventData(updated[0])["trip_id"].(string))
	if err != nil {
		t.Fatalf("trip_updated trip_id: %v", err)
	}
	if start, _ := tripDates(t, tid); start != "2026-06-15" {
		t.Fatalf("trip start = %s, want 2026-06-15", start)
	}
	var trips int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trips WHERE user_id = $1`, user.ID).Scan(&trips); err != nil {
		t.Fatalf("trips count: %v", err)
	}
	if trips != 1 {
		t.Fatalf("trips = %d, want 1", trips)
	}
}

// An editor collaborator refining the owner's trip may shift its dates; the
// analytics event marks the actor as a collaborator.
func TestPlanSetTripDatesEditorCollaborator(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("set_trip_dates", `{"start_date":"2026-06-08"}`),
		textTurn("Shifted for you both."))

	owner, _ := createTestUser(t, "owner@example.com")
	editor, editorToken := createTestUser(t, "editor@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	seedDatedTrip(t, trip, owner.ID)
	if _, err := store.New(dbPool).CreateTripCollaborator(context.Background(), store.CreateTripCollaboratorParams{
		ChatID: *trip.ChatID, OwnerID: owner.ID, UserID: editor.ID, Role: "editor",
	}); err != nil {
		t.Fatalf("seed collaborator: %v", err)
	}

	rec := doJSON(t, "POST", "/api/v1/plan", editorToken, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "shift a week later"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-06-08" || end != "2026-06-12" {
		t.Fatalf("trip dates = %s/%s, want 2026-06-08/2026-06-12", start, end)
	}
	waitForEventCount(t, editor.ID, "agent_trip_dates_set", 1)
}

// Unit-level guards that need no model round-trip.
func TestSetTripDatesToolGuards(t *testing.T) {
	// Anonymous session.
	s, _ := testPlanSession(false, uuid.Nil)
	if msg, isErr := runSetTripDatesTool(s, []byte(`{"start_date":"2026-06-08"}`)); !isErr || !strings.Contains(msg, "signed in") {
		t.Fatalf("anonymous = %q (err=%v)", msg, isErr)
	}

	// Authed but no trip anywhere in the session: directed to create_itinerary.
	resetDB(t)
	user, _ := createTestUser(t, "notrip@example.com")
	s2, _ := testPlanSession(true, user.ID)
	if msg, isErr := runSetTripDatesTool(s2, []byte(`{"start_date":"2026-06-08"}`)); !isErr || !strings.Contains(msg, "create_itinerary") {
		t.Fatalf("no-trip = %q (err=%v)", msg, isErr)
	}

	// Missing start_date.
	if msg, isErr := runSetTripDatesTool(s2, []byte(`{}`)); !isErr || !strings.Contains(msg, "start_date is required") {
		t.Fatalf("missing start = %q (err=%v)", msg, isErr)
	}
}
