package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// The production shape these tests pin (stale-transport-orphans/
// production-audit, 2026-08-22): the route moved Gothenburg → Sorrento to
// Gothenburg → Naples → Sorrento, the booked todo was pruned with the old
// sequence, and the traveler re-ticked "booked" on endpoints they do not
// hold. Migration is the repair: re-key the manual row IN PLACE so the row
// id — and with it the booked flag, the saved shortlist and the linked
// expense — lands on the leg the trip actually flies.

// migrateLegsFixture builds the post-edit sequence: Gothenburg (day 1,
// Sep 10) → Naples (day 4, Sep 13) → Sorrento (day 6, Sep 15) → Rome (day 8,
// Sep 17), trip dates 2026-09-10 → 2026-09-18. The same legs as
// staleTransportFixture, persisted.
func migrateLegsFixture(t *testing.T, owner uuid.UUID) store.Trip {
	t.Helper()
	trip := createTestTrip(t, owner, 0)
	ctx := context.Background()
	if _, err := dbPool.Exec(ctx,
		`UPDATE trips SET start_date = '2026-09-10', end_date = '2026-09-18' WHERE id = $1`,
		trip.ID); err != nil {
		t.Fatalf("date fixture: %v", err)
	}
	q := store.New(dbPool)
	for i, leg := range []struct {
		city string
		day  int32
	}{{"Gothenburg", 1}, {"Naples", 4}, {"Sorrento", 6}, {"Rome", 8}} {
		day := leg.day
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: leg.city + " pin",
			City: &leg.city, Day: &day, Latitude: 57.7, Longitude: 11.9,
		}); err != nil {
			t.Fatalf("leg fixture %s: %v", leg.city, err)
		}
	}
	return trip
}

// addBookedManualTodo posts a custom (auto = false) transport row and ticks
// it booked — the shape a demoted orphan takes. Returns its id.
func addBookedManualTodo(t *testing.T, token, tripID, origin, dest string) string {
	t.Helper()
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/booking-todos", token, map[string]any{
		"kind": "transport", "title": origin + " → " + dest,
		"origin": origin, "destination": dest, "depart_date": "2026-09-11",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add todo = %d: %s", rec.Code, rec.Body.String())
	}
	id := decode(t, rec)["id"].(string)
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+id, token,
		map[string]any{"booked": true})
	if rec.Code != http.StatusOK {
		t.Fatalf("book todo = %d: %s", rec.Code, rec.Body.String())
	}
	return id
}

func migrateTodo(t *testing.T, token, tripID, todoID string) *httptest.ResponseRecorder {
	t.Helper()
	return doJSON(t, "POST",
		fmt.Sprintf("/api/v1/trips/%s/booking-todos/%s/migrate", tripID, todoID), token, nil)
}

func TestMigrateBookingTodo_RekeysInPlace(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-basic@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	tripID := trip.ID.String()
	orphanID := addBookedManualTodo(t, token, tripID, "Gothenburg", "Sorrento")

	rec := migrateTodo(t, token, tripID, orphanID)
	if rec.Code != http.StatusOK {
		t.Fatalf("migrate = %d: %s", rec.Code, rec.Body.String())
	}
	got := decode(t, rec)
	if got["id"] != orphanID {
		t.Fatalf("the row id must survive the move: %v", got["id"])
	}
	if got["todo_key"] != "transport:gothenburg>>naples" {
		t.Fatalf("todo_key = %v", got["todo_key"])
	}
	if got["title"] != "Gothenburg → Naples" {
		t.Fatalf("title = %v", got["title"])
	}
	// The replacement leg's date is Naples' first day, not the old row's.
	if got["depart_date"] != "2026-09-13" {
		t.Fatalf("depart_date = %v", got["depart_date"])
	}
	if got["booked"] != true || got["auto"] != false {
		t.Fatalf("booked/auto = %v/%v — the move preserves the tick and stays manual", got["booked"], got["auto"])
	}
	if url, _ := got["search_url"].(string); url == "" {
		t.Fatalf("search_url must be recomputed for the new leg: %v", got)
	}
}

func TestMigrateBookingTodo_PreservesShortlistAndExpense(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-state@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	tripID := trip.ID.String()
	base := "/api/v1/trips/" + tripID
	orphanID := addBookedManualTodo(t, token, tripID, "Gothenburg", "Sorrento")

	// The two kinds of traveler state keyed on the row id: a saved shortlist
	// (CASCADEs off it) and a linked expense (source_id points at it).
	saveOption(t, token, base, orphanID, map[string]any{"title": "SAS morning flight"})
	if _, err := dbPool.Exec(context.Background(), `INSERT INTO trip_expenses
		(trip_id, category, label, actual_amount, source_kind, source_id)
		VALUES ($1, 'transport', 'Gothenburg → Sorrento flight', 184.50, 'booking_todo', $2)`,
		trip.ID, orphanID); err != nil {
		t.Fatalf("expense fixture: %v", err)
	}

	rec := migrateTodo(t, token, tripID, orphanID)
	if rec.Code != http.StatusOK {
		t.Fatalf("migrate = %d: %s", rec.Code, rec.Body.String())
	}

	tripView := decode(t, doJSON(t, "GET", base, token, nil))
	opts := listOf(t, tripView, "booking_options")
	if len(opts) != 1 || opts[0]["booking_todo_id"] != orphanID {
		t.Fatalf("the shortlist must ride the same row id through the move: %v", opts)
	}
	var linked int
	if err := dbPool.QueryRow(context.Background(), `SELECT count(*) FROM trip_expenses
		WHERE trip_id = $1 AND source_kind = 'booking_todo' AND source_id = $2`,
		trip.ID, orphanID).Scan(&linked); err != nil {
		t.Fatalf("expense check: %v", err)
	}
	if linked != 1 {
		t.Fatalf("the expense link must survive the move, found %d", linked)
	}
}

func TestMigrateBookingTodo_AbsorbsCleanAutoRow(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-absorb@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	tripID := trip.ID.String()

	// The sync's fresh, untouched row for the replacement leg.
	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "transport", "todo_key": "transport:gothenburg>>naples",
			"title": "Gothenburg → Naples", "origin": "Gothenburg", "destination": "Naples",
			"depart_date": "2026-09-13"},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	orphanID := addBookedManualTodo(t, token, tripID, "Gothenburg", "Sorrento")

	rec = migrateTodo(t, token, tripID, orphanID)
	if rec.Code != http.StatusOK {
		t.Fatalf("migrate = %d: %s", rec.Code, rec.Body.String())
	}

	// One row holds the leg afterwards — the migrated manual row, not a
	// duplicate pair.
	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID, token, nil))
	var holders []string
	for _, todo := range listOf(t, tripView, "booking_todos") {
		if todo["todo_key"] == "transport:gothenburg>>naples" {
			holders = append(holders, todo["id"].(string))
		}
	}
	if len(holders) != 1 || holders[0] != orphanID {
		t.Fatalf("exactly one row must hold the new key — the migrated one: %v", holders)
	}
}

func TestMigrateBookingTodo_StateCarryingHolderRefused(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-held@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	tripID := trip.ID.String()

	// The replacement leg's auto row, but the traveler already ticked IT
	// booked — two rows now claim to be the real booking, and choosing
	// between them is the traveler's call, never the tool's.
	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "transport", "todo_key": "transport:gothenburg>>naples",
			"title": "Gothenburg → Naples", "origin": "Gothenburg", "destination": "Naples",
			"depart_date": "2026-09-13"},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	autoID := decodeTodoList(t, rec)[0]["id"].(string)
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+autoID, token,
		map[string]any{"booked": true})
	if rec.Code != http.StatusOK {
		t.Fatalf("book auto row = %d: %s", rec.Code, rec.Body.String())
	}
	orphanID := addBookedManualTodo(t, token, tripID, "Gothenburg", "Sorrento")

	rec = migrateTodo(t, token, tripID, orphanID)
	if rec.Code != http.StatusConflict {
		t.Fatalf("migrate over a state-carrying holder = %d, want 409: %s", rec.Code, rec.Body.String())
	}
	// And nothing moved: the orphan keeps its old title and key.
	row := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID, token, nil))
	for _, todo := range listOf(t, row, "booking_todos") {
		if todo["id"] == orphanID && todo["title"] != "Gothenburg → Sorrento" {
			t.Fatalf("refused migration must leave the row untouched: %v", todo)
		}
	}
}

func TestMigrateBookingTodo_StillAdjacentRefused(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-adjacent@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	tripID := trip.ID.String()
	// Gothenburg → Naples IS an adjacent pair — the tool must not become a
	// way to break a correct chain.
	id := addBookedManualTodo(t, token, tripID, "Gothenburg", "Naples")

	rec := migrateTodo(t, token, tripID, id)
	if rec.Code != http.StatusConflict {
		t.Fatalf("migrate a still-connected row = %d, want 409: %s", rec.Code, rec.Body.String())
	}
}

func TestMigrateBookingTodo_NoReplacementRefused(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-notarget@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	tripID := trip.ID.String()
	// Rome → Gothenburg matches no pair's origin or destination.
	id := addBookedManualTodo(t, token, tripID, "Rome", "Gothenburg")

	rec := migrateTodo(t, token, tripID, id)
	if rec.Code != http.StatusConflict {
		t.Fatalf("migrate with no replacement leg = %d, want 409: %s", rec.Code, rec.Body.String())
	}
}

func TestMigrateBookingTodo_AutoRowRefused(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-auto@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	tripID := trip.ID.String()
	autoID := syncAutoTodo(t, token, tripID)

	rec := migrateTodo(t, token, tripID, autoID)
	if rec.Code != http.StatusConflict {
		t.Fatalf("migrate an auto row = %d, want 409: %s", rec.Code, rec.Body.String())
	}
}

func TestMigrateBookingTodo_NotFound(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "migrate-404@example.com")
	trip := migrateLegsFixture(t, owner.ID)

	rec := migrateTodo(t, token, trip.ID.String(), uuid.NewString())
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown todo = %d, want 404: %s", rec.Code, rec.Body.String())
	}
}
