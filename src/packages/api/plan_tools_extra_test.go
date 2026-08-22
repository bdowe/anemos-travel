package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

// stubWeather wires a WeatherService whose geocode/forecast/archive endpoints
// all answer from one httptest server.
func stubWeather(t *testing.T) (*WeatherService, *[]string) {
	t.Helper()
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/search"):
			fmt.Fprint(w, `{"results":[{"name":"Athens","country":"Greece","latitude":37.98,"longitude":23.72}]}`)
		case strings.HasPrefix(r.URL.Path, "/v1/forecast"):
			fmt.Fprint(w, `{"daily":{"time":["2026-07-10","2026-07-11"],
				"temperature_2m_max":[33.1,34.0],"temperature_2m_min":[24.2,25.0],
				"precipitation_sum":[0,2.4],"precipitation_probability_mean":[5,40]}}`)
		case strings.HasPrefix(r.URL.Path, "/v1/archive"):
			fmt.Fprint(w, `{"daily":{"time":["2025-10-01"],
				"temperature_2m_max":[26.5],"temperature_2m_min":[18.1],
				"precipitation_sum":[3.2]}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	s := NewWeatherService()
	s.GeocodeBaseURL = srv.URL
	s.ForecastBaseURL = srv.URL
	s.ArchiveBaseURL = srv.URL
	return s, &paths
}

func TestGetTripWeatherForecastPath(t *testing.T) {
	s, _ := stubWeather(t)
	start := time.Now().AddDate(0, 0, 3).Format(dateLayout)
	end := time.Now().AddDate(0, 0, 4).Format(dateLayout)

	report, err := s.GetTripWeather(context.Background(), "Athens", start, end)
	if err != nil {
		t.Fatalf("GetTripWeather: %v", err)
	}
	if report.Kind != "forecast" || report.Location != "Athens, Greece" || len(report.Days) != 2 {
		t.Fatalf("report = %+v", report)
	}
	if report.Days[1].PrecipPct == nil || *report.Days[1].PrecipPct != 40 {
		t.Fatalf("forecast day missing precip probability: %+v", report.Days[1])
	}

	text := summarizeWeather(report)
	if !strings.Contains(text, "Forecast for Athens, Greece") || !strings.Contains(text, "40% chance of rain") {
		t.Fatalf("summary wrong:\n%s", text)
	}
}

func TestGetTripWeatherFallsBackToArchive(t *testing.T) {
	s, paths := stubWeather(t)
	// Far beyond the 16-day horizon → last year's observations.
	start := time.Now().AddDate(0, 3, 0).Format(dateLayout)

	report, err := s.GetTripWeather(context.Background(), "Athens", start, "")
	if err != nil {
		t.Fatalf("GetTripWeather: %v", err)
	}
	if report.Kind != "historical" {
		t.Fatalf("kind = %s, want historical", report.Kind)
	}
	var hitArchive bool
	for _, p := range *paths {
		if strings.HasPrefix(p, "/v1/archive") {
			hitArchive = true
		}
		if strings.HasPrefix(p, "/v1/forecast") {
			t.Fatal("far-out dates must not hit the forecast API")
		}
	}
	if !hitArchive {
		t.Fatal("archive API was not called")
	}
	if !strings.Contains(summarizeWeather(report), "Typical weather") {
		t.Fatal("historical summary must be framed as typical, not a forecast")
	}
}

// Mid-trip queries (start date already past) must still use the real
// forecast for the remaining days, clamped to today — not last year's data.
func TestGetTripWeatherMidTripUsesForecast(t *testing.T) {
	s, paths := stubWeather(t)
	start := time.Now().AddDate(0, 0, -3).Format(dateLayout)
	end := time.Now().AddDate(0, 0, 4).Format(dateLayout)

	report, err := s.GetTripWeather(context.Background(), "Athens", start, end)
	if err != nil {
		t.Fatalf("GetTripWeather: %v", err)
	}
	if report.Kind != "forecast" {
		t.Fatalf("mid-trip kind = %s, want forecast", report.Kind)
	}
	for _, p := range *paths {
		if strings.HasPrefix(p, "/v1/archive") {
			t.Fatal("mid-trip query hit the archive API")
		}
	}
}

func TestGetTripWeatherCaches(t *testing.T) {
	s, paths := stubWeather(t)
	start := time.Now().AddDate(0, 0, 3).Format(dateLayout)
	if _, err := s.GetTripWeather(context.Background(), "Athens", start, ""); err != nil {
		t.Fatal(err)
	}
	n := len(*paths)
	if _, err := s.GetTripWeather(context.Background(), "Athens", start, ""); err != nil {
		t.Fatal(err)
	}
	if len(*paths) != n {
		t.Fatalf("second identical lookup hit the network (%d -> %d calls)", n, len(*paths))
	}
}

func TestGetTripToolAnonymous(t *testing.T) {
	msg, isErr := runGetTripTool(context.Background(), false, uuid.Nil, nil, json.RawMessage(`{}`))
	if !isErr || !strings.Contains(msg, "not signed in") {
		t.Fatalf("anonymous get_trip = %q (err=%v)", msg, isErr)
	}
}

// testPlanSession builds the minimal session the booking-todo dispatchers
// need; the recorder doubles as the SSE sink so tests can assert side events.
func testPlanSession(authed bool, uid uuid.UUID) (*planSession, *httptest.ResponseRecorder) {
	rec := httptest.NewRecorder()
	return &planSession{ctx: context.Background(), w: rec, authed: authed, uid: uid}, rec
}

func TestBookingTodoToolsAnonymous(t *testing.T) {
	s, _ := testPlanSession(false, uuid.Nil)
	for name, run := range map[string]func(*planSession, json.RawMessage) (string, bool){
		"add_booking_todo":    runAddBookingTodoTool,
		"update_booking_todo": runUpdateBookingTodoTool,
		"remove_booking_todo": runRemoveBookingTodoTool,
	} {
		msg, isErr := run(s, json.RawMessage(`{}`))
		if !isErr || !strings.Contains(msg, "not signed in") {
			t.Fatalf("anonymous %s = %q (err=%v)", name, msg, isErr)
		}
	}
}

func TestGetTripToolListsAndReads(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	other, _ := createTestUser(t, "other@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	createTestTrip(t, other.ID, 1) // must never appear for owner

	list, isErr := runGetTripTool(context.Background(), true, owner.ID, nil, json.RawMessage(`{}`))
	if isErr || !strings.Contains(list, trip.ID.String()) || !strings.Contains(list, "saved trips (1)") {
		t.Fatalf("list = %q (err=%v)", list, isErr)
	}

	detail, isErr := runGetTripTool(context.Background(), true, owner.ID, nil,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`"}`))
	if isErr || !strings.Contains(detail, "Place 1") || !strings.Contains(detail, "2 places") {
		t.Fatalf("detail = %q (err=%v)", detail, isErr)
	}

	// Cross-user read must fail closed.
	_, isErr = runGetTripTool(context.Background(), true, other.ID, nil,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`"}`))
	if !isErr {
		t.Fatal("cross-user get_trip did not error")
	}
}

func TestAddBookingTodoToolWritesOwnedTripOnly(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	other, _ := createTestUser(t, "other@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	s, rec := testPlanSession(true, owner.ID)
	msg, isErr := runAddBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","kind":"transport","title":"Book Blue Star ferry"}`))
	if isErr || !strings.Contains(msg, "Book Blue Star ferry") {
		t.Fatalf("add = %q (err=%v)", msg, isErr)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("add_booking_todo did not emit trip_updated")
	}

	// Visible through the regular API for the owner.
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	if get.Code != http.StatusOK || !strings.Contains(get.Body.String(), "Book Blue Star ferry") {
		t.Fatalf("todo not on trip: %d %s", get.Code, get.Body.String())
	}

	// Cross-user write must fail closed.
	otherS, _ := testPlanSession(true, other.ID)
	_, isErr = runAddBookingTodoTool(otherS,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","kind":"other","title":"Hijack"}`))
	if !isErr {
		t.Fatal("cross-user add_booking_todo did not error")
	}

	// Bad kind rejected.
	if _, isErr := runAddBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","kind":"spa","title":"x"}`)); !isErr {
		t.Fatal("invalid kind accepted")
	}
}

// seedAgentTodo adds an agent booking todo to the trip and returns its id.
func seedAgentTodo(t *testing.T, s *planSession, tripID uuid.UUID, title string) uuid.UUID {
	t.Helper()
	if msg, isErr := runAddBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+tripID.String()+`","kind":"transport","title":"`+title+`"}`)); isErr {
		t.Fatalf("seed todo: %q", msg)
	}
	var id uuid.UUID
	if err := dbPool.QueryRow(context.Background(),
		`SELECT id FROM booking_todos WHERE trip_id = $1 AND title = $2`, tripID, title).Scan(&id); err != nil {
		t.Fatalf("seeded todo not found: %v", err)
	}
	return id
}

// seedAutoTodo inserts an itinerary-synced (auto=true) row directly.
func seedAutoTodo(t *testing.T, tripID uuid.UUID) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := dbPool.QueryRow(context.Background(),
		`INSERT INTO booking_todos (trip_id, kind, todo_key, title, auto, position)
		 VALUES ($1, 'stay', 'stay:testville', 'Stay in Testville', true, 0) RETURNING id`,
		tripID).Scan(&id); err != nil {
		t.Fatalf("seed auto todo: %v", err)
	}
	return id
}

func TestUpdateBookingTodoToolPartialUpdate(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	other, _ := createTestUser(t, "other@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, rec := testPlanSession(true, owner.ID)
	todoID := seedAgentTodo(t, s, trip.ID, "Book flights EWR to CUR")

	msg, isErr := runUpdateBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`","title":"Book flights EWR to MIA","booked":true}`))
	if isErr || !strings.Contains(msg, "Book flights EWR to MIA") {
		t.Fatalf("update = %q (err=%v)", msg, isErr)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("update_booking_todo did not emit trip_updated")
	}

	// Title and booked changed; untouched fields (kind) survive.
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	body := get.Body.String()
	if !strings.Contains(body, "Book flights EWR to MIA") || strings.Contains(body, "EWR to CUR") {
		t.Fatalf("title not updated: %s", body)
	}
	if !strings.Contains(body, `"booked":true`) || !strings.Contains(body, `"kind":"transport"`) {
		t.Fatalf("partial update clobbered fields: %s", body)
	}

	// Cross-user update must fail closed.
	otherS, _ := testPlanSession(true, other.ID)
	if _, isErr := runUpdateBookingTodoTool(otherS,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`","title":"Hijack"}`)); !isErr {
		t.Fatal("cross-user update_booking_todo did not error")
	}

	// Bad kind, empty title, no fields, unknown id — all rejected.
	for name, input := range map[string]string{
		"invalid kind": `{"trip_id":"` + trip.ID.String() + `","todo_id":"` + todoID.String() + `","kind":"spa"}`,
		"empty title":  `{"trip_id":"` + trip.ID.String() + `","todo_id":"` + todoID.String() + `","title":"  "}`,
		"no fields":    `{"trip_id":"` + trip.ID.String() + `","todo_id":"` + todoID.String() + `"}`,
		"unknown id":   `{"trip_id":"` + trip.ID.String() + `","todo_id":"` + uuid.NewString() + `","title":"x"}`,
	} {
		if _, isErr := runUpdateBookingTodoTool(s, json.RawMessage(input)); !isErr {
			t.Fatalf("%s accepted", name)
		}
	}
}

func TestRemoveBookingTodoTool(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	other, _ := createTestUser(t, "other@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, rec := testPlanSession(true, owner.ID)
	todoID := seedAgentTodo(t, s, trip.ID, "Book flights EWR to CUR")

	// Cross-user remove must fail closed (and leave the row).
	otherS, _ := testPlanSession(true, other.ID)
	if _, isErr := runRemoveBookingTodoTool(otherS,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`"}`)); !isErr {
		t.Fatal("cross-user remove_booking_todo did not error")
	}

	msg, isErr := runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`"}`))
	if isErr {
		t.Fatalf("remove = %q (err=%v)", msg, isErr)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("remove_booking_todo did not emit trip_updated")
	}
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	if strings.Contains(get.Body.String(), "EWR to CUR") {
		t.Fatalf("todo still on trip: %s", get.Body.String())
	}

	// Removing again reports the friendly miss.
	if msg, isErr := runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`"}`)); !isErr || !strings.Contains(msg, "No such checklist item") {
		t.Fatalf("double remove = %q (err=%v)", msg, isErr)
	}
}

func TestBookingTodoToolsRefuseAutoRows(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	autoID := seedAutoTodo(t, trip.ID)
	s, _ := testPlanSession(true, owner.ID)

	if msg, isErr := runUpdateBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+autoID.String()+`","title":"Overwrite"}`)); !isErr || !strings.Contains(msg, "auto") {
		t.Fatalf("auto row updated: %q (err=%v)", msg, isErr)
	}
	if msg, isErr := runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+autoID.String()+`"}`)); !isErr || !strings.Contains(msg, "auto") {
		t.Fatalf("auto row removed: %q (err=%v)", msg, isErr)
	}
	var n int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM booking_todos WHERE id = $1`, autoID).Scan(&n); err != nil || n != 1 {
		t.Fatalf("auto row gone (n=%d, err=%v)", n, err)
	}
}

// seedTodoOption saves a booking-shortlist candidate off the given todo (00065:
// booking_options CASCADEs off booking_todos, so a delete destroys it).
func seedTodoOption(t *testing.T, tripID, todoID uuid.UUID, title string) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`INSERT INTO booking_options (trip_id, booking_todo_id, title) VALUES ($1, $2, $3)`,
		tripID, todoID, title); err != nil {
		t.Fatalf("seed option: %v", err)
	}
}

// seedTodoExpense links a paid budget expense to the given todo via 00061's
// untyped (source_kind, source_id) pair — no FK, so a delete leaves it dangling.
func seedTodoExpense(t *testing.T, tripID, todoID uuid.UUID) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`INSERT INTO trip_expenses (trip_id, label, amount, actual_amount, source_kind, source_id)
		 VALUES ($1, 'Flight deposit', 120, 120, 'booking_todo', $2)`,
		tripID, todoID); err != nil {
		t.Fatalf("seed expense: %v", err)
	}
}

func countTodoRows(t *testing.T, id uuid.UUID) int {
	t.Helper()
	var n int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM booking_todos WHERE id = $1`, id).Scan(&n); err != nil {
		t.Fatalf("count todo: %v", err)
	}
	return n
}

// A booked manual row is the production case (agent_booking_todo_removed,
// 2026-08-20 20:49:43 UTC, trip 4a72c44c): the agent hard-deleted the app's
// last record of a reservation the traveler actually holds. The tool must
// refuse, naming the reservation risk and the confirm path.
func TestRemoveBookingTodoToolRefusesBookedRow(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	seed, _ := testPlanSession(true, owner.ID)
	todoID := seedAgentTodo(t, seed, trip.ID, "Book flights Gothenburg to Sorrento")
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE booking_todos SET booked = true WHERE id = $1`, todoID); err != nil {
		t.Fatalf("mark booked: %v", err)
	}

	s, rec := testPlanSession(true, owner.ID)
	msg, isErr := runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`"}`))
	if !isErr {
		t.Fatalf("booked row removed without confirm: %q", msg)
	}
	for _, want := range []string{
		`"Book flights Gothenburg to Sorrento"`, // names the row
		"booked",
		"reservation",
		"only the traveler can cancel",
		"confirm: true", // names the call that works
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("refusal missing %q:\n%s", want, msg)
		}
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("refusal emitted trip_updated")
	}
	if n := countTodoRows(t, todoID); n != 1 {
		t.Fatalf("refusal deleted the row (n=%d)", n)
	}
}

// The rest of the demote predicate (minus mode): a saved shortlist and a
// linked expense are also state a hard delete silently destroys.
func TestRemoveBookingTodoToolRefusesOptionAndExpenseRows(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	seed, _ := testPlanSession(true, owner.ID)
	s, rec := testPlanSession(true, owner.ID)

	optTodo := seedAgentTodo(t, seed, trip.ID, "Book Naples stay")
	seedTodoOption(t, trip.ID, optTodo, "Loft near Old Town")
	seedTodoOption(t, trip.ID, optTodo, "B&B by the port")

	expTodo := seedAgentTodo(t, seed, trip.ID, "Book Sorrento ferry")
	seedTodoExpense(t, trip.ID, expTodo)

	rec.Body.Reset()
	msg, isErr := runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+optTodo.String()+`"}`))
	if !isErr {
		t.Fatalf("shortlist row removed without confirm: %q", msg)
	}
	for _, want := range []string{`"Book Naples stay"`, "shortlist", "2 options", "confirm: true"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("shortlist refusal missing %q:\n%s", want, msg)
		}
	}

	rec.Body.Reset()
	msg, isErr = runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+expTodo.String()+`"}`))
	if !isErr {
		t.Fatalf("expense-linked row removed without confirm: %q", msg)
	}
	for _, want := range []string{`"Book Sorrento ferry"`, "expense", "confirm: true"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("expense refusal missing %q:\n%s", want, msg)
		}
	}

	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("refusal emitted trip_updated")
	}
	if countTodoRows(t, optTodo) != 1 || countTodoRows(t, expTodo) != 1 {
		t.Fatal("refusal deleted a row")
	}
}

// confirm: true is the escape hatch: the delete proceeds and the result names
// the row and what went with it (replace_leg's name-it-back idiom).
func TestRemoveBookingTodoToolConfirmDeletesStateRow(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	seed, _ := testPlanSession(true, owner.ID)
	s, rec := testPlanSession(true, owner.ID)

	todoID := seedAgentTodo(t, seed, trip.ID, "Book flights Gothenburg to Sorrento")
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE booking_todos SET booked = true WHERE id = $1`, todoID); err != nil {
		t.Fatalf("mark booked: %v", err)
	}
	seedTodoOption(t, trip.ID, todoID, "Ryanair FR123")
	seedTodoOption(t, trip.ID, todoID, "Norwegian DY456")
	seedTodoExpense(t, trip.ID, todoID)

	rec.Body.Reset()
	msg, isErr := runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+todoID.String()+`","confirm":true}`))
	if isErr {
		t.Fatalf("confirmed remove refused: %q", msg)
	}
	for _, want := range []string{
		`"Book flights Gothenburg to Sorrento"`, // names the row
		"shortlist",                             // what went with it
		"expense",                               // what went with it
		"not cancel",                            // the provider-side reservation warning
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("confirmed result missing %q:\n%s", want, msg)
		}
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("confirmed remove did not emit trip_updated")
	}
	if n := countTodoRows(t, todoID); n != 0 {
		t.Fatalf("confirmed remove left the row (n=%d)", n)
	}
	var optCount int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM booking_options WHERE booking_todo_id = $1`, todoID).Scan(&optCount); err != nil || optCount != 0 {
		t.Fatalf("shortlist survived the cascade (n=%d, err=%v)", optCount, err)
	}
	// The expense survives, dangling by design (00061 has no FK).
	var expCount int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_expenses WHERE source_kind = 'booking_todo' AND source_id = $1`, todoID).Scan(&expCount); err != nil || expCount != 1 {
		t.Fatalf("linked expense gone (n=%d, err=%v)", expCount, err)
	}

	// confirm on a plain row is still the ordinary happy path.
	plainID := seedAgentTodo(t, seed, trip.ID, "Book travel insurance")
	if msg, isErr := runRemoveBookingTodoTool(s,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+plainID.String()+`","confirm":true}`)); isErr {
		t.Fatalf("confirmed plain remove refused: %q", msg)
	}
	if n := countTodoRows(t, plainID); n != 0 {
		t.Fatalf("confirmed plain remove left the row (n=%d)", n)
	}
}

// boundPlanSession is testPlanSession bound to a trip the caller owns — the
// setup the three trip-acting tools require.
func boundPlanSession(uid, tripID uuid.UUID) (*planSession, *httptest.ResponseRecorder) {
	s, rec := testPlanSession(true, uid)
	s.boundTripID = &tripID
	s.boundTripOwnerID = uid
	return s, rec
}

func TestAgentFixToolsGuardWhenUnbound(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")

	// Unbound (no open trip) → friendly error, no write.
	unbound, _ := testPlanSession(true, owner.ID)
	for name, run := range map[string]func(*planSession, json.RawMessage) (string, bool){
		"add_accommodation":     runAddAccommodationTool,
		"add_transport_segment": runAddTransportSegmentTool,
		"move_itinerary_item":   runMoveItineraryItemTool,
	} {
		msg, isErr := run(unbound, json.RawMessage(`{"name":"x","mode":"ferry","item_id":"`+uuid.NewString()+`","day":1}`))
		if !isErr || !strings.Contains(msg, "No trip is open") {
			t.Fatalf("unbound %s = %q (err=%v)", name, msg, isErr)
		}
	}

	// Unauthed → friendly error, no write.
	anon, _ := testPlanSession(false, uuid.Nil)
	tid := uuid.New()
	anon.boundTripID = &tid
	for name, run := range map[string]func(*planSession, json.RawMessage) (string, bool){
		"add_accommodation":     runAddAccommodationTool,
		"add_transport_segment": runAddTransportSegmentTool,
		"move_itinerary_item":   runMoveItineraryItemTool,
	} {
		msg, isErr := run(anon, json.RawMessage(`{"name":"x","mode":"ferry","item_id":"`+uuid.NewString()+`","day":1}`))
		if !isErr || !strings.Contains(msg, "isn't signed in") {
			t.Fatalf("anon %s = %q (err=%v)", name, msg, isErr)
		}
	}
}

func TestSetTravelModeTool(t *testing.T) {
	resetDB(t)

	// Invalid mode → error, session untouched.
	anon, _ := testPlanSession(false, uuid.Nil)
	if msg, isErr := runSetTravelModeTool(anon, json.RawMessage(`{"mode":"teleport"}`)); !isErr {
		t.Fatalf("invalid mode accepted: %q", msg)
	}
	if anon.travelMode != "" {
		t.Fatalf("session mode after invalid input = %q", anon.travelMode)
	}

	// Anonymous/unbound → success, session-only, promises to apply at save.
	msg, isErr := runSetTravelModeTool(anon, json.RawMessage(`{"mode":"car"}`))
	if isErr || anon.travelMode != "car" {
		t.Fatalf("anon set = %q (err=%v, mode=%q)", msg, isErr, anon.travelMode)
	}
	if !strings.Contains(msg, "do not search or suggest flights") ||
		!strings.Contains(msg, "saved with the itinerary") {
		t.Fatalf("anon note = %q", msg)
	}

	// Bound trip → row updated immediately + trip_updated SSE.
	owner, ownerToken := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, rec := boundPlanSession(owner.ID, trip.ID)
	msg, isErr = runSetTravelModeTool(s, json.RawMessage(`{"mode":"train"}`))
	if isErr || s.travelMode != "train" {
		t.Fatalf("bound set = %q (err=%v, mode=%q)", msg, isErr, s.travelMode)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("set_travel_mode did not emit trip_updated")
	}
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	if get.Code != http.StatusOK || !strings.Contains(get.Body.String(), `"travel_mode":"train"`) {
		t.Fatalf("travel_mode not on trip: %d %s", get.Code, get.Body.String())
	}
}

func TestAddAccommodationToolWritesBoundTrip(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, rec := boundPlanSession(owner.ID, trip.ID)

	msg, isErr := runAddAccommodationTool(s,
		json.RawMessage(`{"name":"Hotel Grande Bretagne","check_in":"2026-08-03","check_out":"2026-08-05"}`))
	if isErr || !strings.Contains(msg, "Hotel Grande Bretagne") {
		t.Fatalf("add = %q (err=%v)", msg, isErr)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("add_accommodation did not emit trip_updated")
	}
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	if get.Code != http.StatusOK || !strings.Contains(get.Body.String(), "Hotel Grande Bretagne") {
		t.Fatalf("stay not on trip: %d %s", get.Code, get.Body.String())
	}

	// Missing name rejected, no write.
	if _, isErr := runAddAccommodationTool(s, json.RawMessage(`{"name":"  "}`)); !isErr {
		t.Fatal("blank name accepted")
	}
}

func TestAddTransportSegmentToolWritesBoundTrip(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, rec := boundPlanSession(owner.ID, trip.ID)

	msg, isErr := runAddTransportSegmentTool(s,
		json.RawMessage(`{"mode":"ferry","origin":"Athens","destination":"Naxos","depart_date":"2026-08-04"}`))
	// The echo is phrased by segmentSummaryLine — the SAME sentence get_trip
	// prints on the next read, so the model can verify its own write.
	if isErr || !strings.Contains(msg, "ferry Athens -> Naxos, departs 2026-08-04") {
		t.Fatalf("add = %q (err=%v)", msg, isErr)
	}
	// A same-day leg must NOT carry the overnight clause.
	if strings.Contains(msg, "lands the day AFTER") {
		t.Fatalf("same-day leg described as overnight: %q", msg)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("add_transport_segment did not emit trip_updated")
	}
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	if get.Code != http.StatusOK || !strings.Contains(get.Body.String(), "Naxos") {
		t.Fatalf("segment not on trip: %d %s", get.Code, get.Body.String())
	}

	// Bad mode rejected, no write.
	if _, isErr := runAddTransportSegmentTool(s, json.RawMessage(`{"mode":"teleport"}`)); !isErr {
		t.Fatal("invalid mode accepted")
	}
}

// TestAddTransportSegmentToolRecordsOvernightArrival is the agent half of
// specs-less overnight-arrival work: the model reads "21:55→11:30+1" out of
// summarizeOffers and, before this, had nowhere to put the +1. Both dates must
// persist, and the echo must state the post-state INCLUDING the non-change —
// that day 1 is still the arrival day — because "move the trip's start date
// back" is the one wrong inference recording a departure invites.
func TestAddTransportSegmentToolRecordsOvernightArrival(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, _ := boundPlanSession(owner.ID, trip.ID)

	msg, isErr := runAddTransportSegmentTool(s, json.RawMessage(
		`{"mode":"flight","origin":"EWR","destination":"Amsterdam","depart_date":"2026-08-23","arrive_date":"2026-08-24"}`))
	if isErr {
		t.Fatalf("overnight leg rejected: %q", msg)
	}
	if !strings.Contains(msg, "departs 2026-08-23") || !strings.Contains(msg, "arrives 2026-08-24") {
		t.Fatalf("echo dropped a date: %q", msg)
	}
	if !strings.Contains(msg, "day 1 is still the ARRIVAL day") {
		t.Fatalf("echo did not pin the non-change: %q", msg)
	}

	// Both dates round-trip onto the trip.
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	if get.Code != http.StatusOK {
		t.Fatalf("get trip: %d", get.Code)
	}
	if !strings.Contains(get.Body.String(), `"arrive_date":"2026-08-24"`) ||
		!strings.Contains(get.Body.String(), `"depart_date":"2026-08-23"`) {
		t.Fatalf("segment dates not persisted: %s", get.Body.String())
	}

	// get_trip speaks the same sentence the echo did — one helper, so a write
	// result and the next read can never drift apart.
	view, _ := runGetTripTool(s.ctx, true, owner.ID, &trip.ID,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`"}`))
	if !strings.Contains(view, "departs 2026-08-23, arrives 2026-08-24") {
		t.Fatalf("get_trip disagrees with the write echo: %q", view)
	}
}

// TestAddTransportSegmentToolRejectsBackwardsArrival mirrors the REST guard so
// the agent path cannot write a pair the traveler's own sheet is refused for.
// Asserts NO write, not merely an error.
func TestAddTransportSegmentToolRejectsBackwardsArrival(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, _ := boundPlanSession(owner.ID, trip.ID)

	for _, bad := range []string{
		`{"mode":"flight","origin":"EWR","destination":"Amsterdam","depart_date":"2026-08-24","arrive_date":"2026-08-23"}`,
		`{"mode":"flight","origin":"EWR","destination":"Amsterdam","arrive_date":"next tuesday"}`,
	} {
		if msg, isErr := runAddTransportSegmentTool(s, json.RawMessage(bad)); !isErr {
			t.Fatalf("accepted %s => %q", bad, msg)
		}
	}
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	if strings.Contains(get.Body.String(), "Amsterdam") {
		t.Fatalf("rejected input still wrote a segment: %s", get.Body.String())
	}
}

// TestAddTransportSegmentSchemaAdvertisesArriveDate — a dispatcher reading a
// parameter the schema never advertises is dead code that looks alive.
func TestAddTransportSegmentSchemaAdvertisesArriveDate(t *testing.T) {
	if _, ok := addTransportSegmentTool.InputSchema.Properties.(map[string]any)["arrive_date"]; !ok {
		t.Fatal("add_transport_segment does not advertise arrive_date")
	}
}

func TestMoveItineraryItemToolMovesItem(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	s, rec := boundPlanSession(owner.ID, trip.ID)

	var itemID uuid.UUID
	if err := dbPool.QueryRow(context.Background(),
		`SELECT id FROM itinerary_items WHERE trip_id = $1 AND name = 'Place 1'`, trip.ID).Scan(&itemID); err != nil {
		t.Fatalf("item not found: %v", err)
	}

	msg, isErr := runMoveItineraryItemTool(s,
		json.RawMessage(`{"item_id":"`+itemID.String()+`","day":3,"time_of_day":"evening"}`))
	if isErr || !strings.Contains(msg, "Day 3") {
		t.Fatalf("move = %q (err=%v)", msg, isErr)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("move_itinerary_item did not emit trip_updated")
	}
	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil)
	body := get.Body.String()
	if !strings.Contains(body, `"day":3`) || !strings.Contains(body, `"time_of_day":"evening"`) {
		t.Fatalf("move not persisted: %s", body)
	}

	// An item on another trip must not be movable through this session.
	otherTrip := createTestTrip(t, owner.ID, 1)
	var otherItem uuid.UUID
	if err := dbPool.QueryRow(context.Background(),
		`SELECT id FROM itinerary_items WHERE trip_id = $1 LIMIT 1`, otherTrip.ID).Scan(&otherItem); err != nil {
		t.Fatalf("other item not found: %v", err)
	}
	if _, isErr := runMoveItineraryItemTool(s,
		json.RawMessage(`{"item_id":"`+otherItem.String()+`","day":1}`)); !isErr {
		t.Fatal("moved an item that belongs to another trip")
	}

	// Bad day rejected.
	if _, isErr := runMoveItineraryItemTool(s,
		json.RawMessage(`{"item_id":"`+itemID.String()+`","day":0}`)); !isErr {
		t.Fatal("day 0 accepted")
	}
}

func TestFormatReviewFindingsStructuredTail(t *testing.T) {
	checkIn, checkOut := "2026-08-03", "2026-08-04"
	city := "Naxos"
	day3 := 3
	itemID := uuid.NewString()
	findings := []Finding{
		{Severity: "warn", Category: "lodging", Message: "No lodging booked for the night of Mon, Aug 3.", Day: &day3,
			Fix: &FindingFix{Action: "add_lodging", CheckIn: &checkIn, CheckOut: &checkOut, City: &city}},
		{Severity: "warn", Category: "hours", Message: "The Acropolis may be closed on Monday (Day 3).", ItemID: &itemID,
			Fix: &FindingFix{Action: "move_item", ItemID: &itemID, TargetDay: &day3}},
	}
	step := &NextStep{Kind: "add_lodging", Title: "Book a place to stay",
		Detail: "No lodging booked for the night of Mon, Aug 3."}
	out := formatReviewFindings(findings, step)
	if !strings.Contains(out, "[fix: category=lodging fix=add_lodging check_in=2026-08-03 check_out=2026-08-04 city=Naxos]") {
		t.Fatalf("lodging tail missing:\n%s", out)
	}
	if !strings.Contains(out, "item_id="+itemID) || !strings.Contains(out, "fix=move_item") || !strings.Contains(out, "target_day=3") {
		t.Fatalf("move tail missing:\n%s", out)
	}
	if !strings.Contains(out, "Suggested next step: Book a place to stay") ||
		!strings.Contains(out, "[next_step: kind=add_lodging]") {
		t.Fatalf("next-step line missing:\n%s", out)
	}
	// A past trip (nil step) narrates findings only; an all-set step says so.
	if noStep := formatReviewFindings(findings, nil); strings.Contains(noStep, "Suggested next step") {
		t.Fatalf("nil step still narrated:\n%s", noStep)
	}
	if done := formatReviewFindings(nil, &NextStep{Kind: "all_set", Title: "You're all set"}); !strings.Contains(done, "kind=all_set") {
		t.Fatalf("all_set narration missing:\n%s", done)
	}
}

func TestGetTripToolShowsBookingChecklist(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	s, _ := testPlanSession(true, owner.ID)
	todoID := seedAgentTodo(t, s, trip.ID, "Book flights EWR to CUR")
	seedAutoTodo(t, trip.ID)

	detail, isErr := runGetTripTool(context.Background(), true, owner.ID, nil,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`"}`))
	if isErr {
		t.Fatalf("detail errored: %q", detail)
	}
	if !strings.Contains(detail, "Booking checklist (2 items)") ||
		!strings.Contains(detail, "todo_id: "+todoID.String()) ||
		!strings.Contains(detail, "agent-added") {
		t.Fatalf("checklist missing from detail:\n%s", detail)
	}
	if !strings.Contains(detail, "auto — tracks the itinerary; not editable") {
		t.Fatalf("auto marker missing from detail:\n%s", detail)
	}
}

// get_trip must expose stay/transport dates so the model can verify the
// calendar state it narrates after a date-change tool; auto drafts stay
// invisible.
func TestGetTripToolShowsStayAndTransportDates(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedMultiCityTrip(t, trip, owner.ID)

	detail, isErr := runGetTripTool(context.Background(), true, owner.ID, nil,
		json.RawMessage(`{"trip_id":"`+trip.ID.String()+`"}`))
	if isErr {
		t.Fatalf("detail errored: %q", detail)
	}
	for _, want := range []string{
		"City legs as rendered on the trip page (arrival to departure):",
		"- Panama City: 2026-09-15 to 2026-09-20",
		"- Los Angeles: 2026-09-20 to 2026-09-24",
		"Stays:",
		`"Hotel Casco Viejo" 2026-09-15 to 2026-09-20 (not booked)`,
		`"Stay in Los Angeles" 2026-09-20 to 2026-09-24 (not booked)`,
		"Transport:",
		"flight Panama City -> Los Angeles, departs 2026-09-20",
		"flight Los Angeles -> Newark, departs 2026-09-24",
	} {
		if !strings.Contains(detail, want) {
			t.Fatalf("detail missing %q:\n%s", want, detail)
		}
	}
	if strings.Contains(detail, "Suggested stay in Los Angeles") {
		t.Fatalf("auto draft leaked into detail:\n%s", detail)
	}
}

// create_itinerary must echo the same rendered leg ranges its sibling writer
// does. It matters most on the shape this test builds: the last day carries
// NOTHING (it's the journey home), so the itinerary's own day numbers stop a
// day short of the trip. Only the echo can tell the model that Amsterdam still
// renders through Aug 25 — without it the model sees a 2-day itinerary on a
// 3-day trip and "fixes" a range that was never wrong.
func TestCreateItineraryResultShowsRenderedLegs(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "createlegs@example.com")

	s, _ := testPlanSession(true, owner.ID)
	msg, isErr := runCreateItineraryTool(s, json.RawMessage(
		`{"title":"Amsterdam","start_date":"2026-08-23","end_date":"2026-08-25","locations":[`+
			`{"name":"Rijksmuseum","latitude":52.36,"longitude":4.885,"day":1,"city":"Amsterdam"},`+
			`{"name":"Anne Frank House","latitude":52.375,"longitude":4.884,"day":2,"city":"Amsterdam"}]}`))
	if isErr {
		t.Fatalf("create errored: %s", msg)
	}
	for _, want := range []string{
		"Itinerary created successfully.",
		"The page now renders these city legs:",
		// Day 2 is Aug 24; the leg still runs to the trip's end date.
		"- Amsterdam: 2026-08-23 to 2026-08-25",
		"leaving the day home empty does not shorten it",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q:\n%s", want, msg)
		}
	}
	// Every plannable day here carries a place, so the open-days note must be
	// ABSENT. Pinned rather than left incidental: the note is meant for the days
	// a spine deliberately leaves open, and boilerplate on every write would
	// teach the model to ignore it.
	if strings.Contains(msg, "Days with nothing planned yet") {
		t.Fatalf("a fully covered itinerary named open days:\n%s", msg)
	}
}

// A section rewrite's result must echo the rendered leg ranges — day numbers
// are positional, so a wrong day->date mental model would otherwise survive
// any number of "successful" rewrites (the Sep-24-27 loop).
func TestUpdateItinerarySectionResultShowsRenderedLegs(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "sectionlegs@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedMultiCityTrip(t, trip, owner.ID)

	s, rec := testPlanSession(true, owner.ID)
	s.boundTripID = &trip.ID
	s.boundTripOwnerID = owner.ID
	msg, isErr := runUpdateItinerarySectionTool(s, json.RawMessage(
		`{"scope":"trip","items":[`+
			`{"name":"PC Spot 1","latitude":8.98,"longitude":-79.52,"day":1,"city":"Panama City"},`+
			`{"name":"LA Spot 1","latitude":34.05,"longitude":-118.24,"day":9,"city":"Los Angeles"}]}`))
	if isErr {
		t.Fatalf("section rewrite errored: %s", msg)
	}
	for _, want := range []string{
		"Section updated",
		"The page now renders these city legs:",
		"- Panama City: 2026-09-15 to 2026-09-20",
		// LA's single item landed on day 9 (Sep 23); its leg renders from the
		// stay-anchored span, which the rewrite did not touch.
		"- Los Angeles: 2026-09-20 to 2026-09-24",
		"do NOT resend the list with recomputed day numbers",
		"set_leg_dates",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q:\n%s", want, msg)
		}
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("section rewrite did not emit trip_updated")
	}
}

// The other half of an itinerary write's post-state, and the half a SPINE makes
// load-bearing (specs/shape-before-schedule): with the middle of every stay
// empty by agreement, "Itinerary created successfully" plus a list of leg
// ranges no longer describes what the traveler will see.
//
// The day-4 and day-6 pairs are the travel days — the place the traveler leaves
// in the morning and the one they arrive at in the evening. The time_of_day
// split is not decoration: it keeps the two cities' places in separate
// reorderItineraryByDistance blocks, so the walking-distance pass cannot
// interleave them and split a leg.
func TestCreateItineraryResultNamesOpenDays(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "opendays@example.com")

	s, _ := testPlanSession(true, owner.ID)
	msg, isErr := runCreateItineraryTool(s, json.RawMessage(
		`{"title":"Iberia","start_date":"2026-09-01","end_date":"2026-09-08","locations":[`+
			`{"name":"Time Out Market","latitude":38.70,"longitude":-9.14,"day":1,"city":"Lisbon","time_of_day":"evening"},`+
			`{"name":"Pasteis de Belem","latitude":38.69,"longitude":-9.20,"day":4,"city":"Lisbon","time_of_day":"morning"},`+
			`{"name":"Livraria Lello","latitude":41.14,"longitude":-8.61,"day":4,"city":"Porto","time_of_day":"evening"},`+
			`{"name":"Cais da Ribeira","latitude":41.14,"longitude":-8.61,"day":6,"city":"Porto","time_of_day":"morning"},`+
			`{"name":"Museo del Prado","latitude":40.41,"longitude":-3.69,"day":6,"city":"Madrid","time_of_day":"evening"}]}`))
	if isErr {
		t.Fatalf("spine write errored: %s", msg)
	}
	for _, want := range []string{
		// A sparse itinerary renders the same ranges a dense one would.
		"- Lisbon: 2026-09-01 to 2026-09-04 (3 nights, dated by its places)",
		"- Porto: 2026-09-04 to 2026-09-06 (2 nights, dated by its places)",
		"- Madrid: 2026-09-06 to 2026-09-08 (2 nights, dated by its places)",
		"Days with nothing planned yet:",
		"days 2-3 in Lisbon",
		"day 5 in Porto",
		"day 7 in Madrid",
		"do NOT fill them in this turn",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q:\n%s", want, msg)
		}
	}
	// Day 8 is the journey home — not a plannable day. This assertion is what
	// catches a future refactor away from walkDayCoverage, which is the only
	// reason the day the traveler flies back can never be offered as "open".
	if strings.Contains(msg, "day 8") {
		t.Fatalf("the journey-home day was offered as open:\n%s", msg)
	}
	// A well-formed spine is not a problem, and must not be reported as one.
	if strings.Contains(msg, "WARNING") {
		t.Fatalf("a well-formed spine warned:\n%s", msg)
	}
}

// The failure the whole design rests on not happening, seen from the model's
// side: a city with no place on the day the traveler moves on renders zero
// nights and the next city absorbs them. Nothing on the trip page says so — no
// nights label is drawn below one night — so the tool result is the only place
// this is visible on the turn that caused it.
func TestCreateItineraryResultWarnsOnACollapsedLeg(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "collapsedleg@example.com")

	s, _ := testPlanSession(true, owner.ID)
	msg, isErr := runCreateItineraryTool(s, json.RawMessage(
		`{"title":"Iberia","start_date":"2026-09-01","end_date":"2026-09-08","locations":[`+
			`{"name":"Time Out Market","latitude":38.70,"longitude":-9.14,"day":1,"city":"Lisbon"},`+
			`{"name":"Livraria Lello","latitude":41.14,"longitude":-8.61,"day":4,"city":"Porto"}]}`))
	if isErr {
		t.Fatalf("write errored: %s", msg)
	}
	for _, want := range []string{
		"WARNING", "Lisbon renders ZERO nights", "the next city has absorbed those nights",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q:\n%s", want, msg)
		}
	}
}

// The three mechanical refusals reach the model through the tool and, crucially,
// leave the database untouched: no trip row, no `done` event, nothing for the
// traveler's page to show. The model retries against an unchanged world.
func TestCreateItineraryRefusesAndPersistsNothing(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "refusals@example.com")

	cases := []struct {
		name, input, want string
	}{
		{"start without end", `{"start_date":"2026-09-01","locations":[{"name":"Prado","latitude":40.41,"longitude":-3.69,"day":1,"city":"Madrid"}]}`, "end_date is required"},
		{"dated trip, undated place", `{"start_date":"2026-09-01","end_date":"2026-09-08","locations":[{"name":"Prado","latitude":40.41,"longitude":-3.69,"city":"Madrid"}]}`, "Every place needs a day"},
		{"mixed hub tagging", `{"start_date":"2026-09-01","end_date":"2026-09-08","locations":[{"name":"Prado","latitude":40.41,"longitude":-3.69,"day":1,"city":"Madrid"},{"name":"Lello","latitude":41.14,"longitude":-8.61,"day":4}]}`, "Every place needs the city it is in"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, rec := testPlanSession(true, owner.ID)
			msg, isErr := runCreateItineraryTool(s, json.RawMessage(tc.input))
			if !isErr {
				t.Fatalf("write was accepted: %s", msg)
			}
			if !strings.Contains(msg, tc.want) {
				t.Fatalf("refusal = %q, want it to contain %q", msg, tc.want)
			}
			if s.tripID != nil {
				t.Fatal("a refused write still bound a trip to the session")
			}
			if strings.Contains(rec.Body.String(), "event: done") {
				t.Fatalf("a refused write still streamed a done event:\n%s", rec.Body.String())
			}
			var trips int
			if err := dbPool.QueryRow(context.Background(),
				`SELECT count(*) FROM trips WHERE user_id = $1`, owner.ID).Scan(&trips); err != nil {
				t.Fatalf("trips count: %v", err)
			}
			if trips != 0 {
				t.Fatalf("trips = %d, want 0 — a refused write persisted", trips)
			}
		})
	}
}
