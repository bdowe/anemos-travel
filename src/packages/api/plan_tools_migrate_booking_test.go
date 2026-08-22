package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// The tool is the model's half of the move — strictly safer than the
// remove_booking_todo it reached for on 2026-08-20. The write itself is
// pinned end-to-end in booking_todo_migrate_integration_test.go; these pin
// the tool surface: the gates, the authz boundary, and the name-every-change
// result idiom.

func TestMigrateBookingTodoToolAnonymous(t *testing.T) {
	s, _ := testPlanSession(false, uuid.Nil)
	msg, isErr := runMigrateBookingTodoTool(s, json.RawMessage(`{}`))
	if !isErr || !strings.Contains(msg, "not signed in") {
		t.Fatalf("anonymous migrate_booking_todo = %q (err=%v)", msg, isErr)
	}
}

func TestMigrateBookingTodoToolNamesTheMove(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent-migrate@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	orphanID := addBookedManualTodo(t, ownerToken, trip.ID.String(), "Gothenburg", "Sorrento")

	s, rec := testPlanSession(true, owner.ID)
	msg, isErr := runMigrateBookingTodoTool(s, json.RawMessage(
		`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+orphanID+`"}`))
	if isErr {
		t.Fatalf("migrate = %q (err=%v)", msg, isErr)
	}
	// The replace_leg idiom: both pairs named, the carried-over state named,
	// and the provider-side reservation explicitly out of scope.
	for _, want := range []string{
		"Gothenburg → Sorrento", "Gothenburg → Naples", "2026-09-13",
		"booked tick", "reservation itself",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result must name %q: %s", want, msg)
		}
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("migrate_booking_todo did not emit trip_updated")
	}
	row := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil))
	for _, todo := range listOf(t, row, "booking_todos") {
		if todo["id"] == orphanID && todo["todo_key"] != "transport:gothenburg>>naples" {
			t.Fatalf("the row was not re-keyed: %v", todo)
		}
	}
}

func TestMigrateBookingTodoToolCrossUserFailsClosed(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent-migrate-owner@example.com")
	other, _ := createTestUser(t, "agent-migrate-other@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	orphanID := addBookedManualTodo(t, ownerToken, trip.ID.String(), "Gothenburg", "Sorrento")

	otherS, _ := testPlanSession(true, other.ID)
	if _, isErr := runMigrateBookingTodoTool(otherS, json.RawMessage(
		`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+orphanID+`"}`)); !isErr {
		t.Fatal("cross-user migrate_booking_todo did not error")
	}
	// And the row is untouched.
	row := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), ownerToken, nil))
	for _, todo := range listOf(t, row, "booking_todos") {
		if todo["id"] == orphanID && todo["title"] != "Gothenburg → Sorrento" {
			t.Fatalf("cross-user attempt moved the row: %v", todo)
		}
	}
}

func TestMigrateBookingTodoToolRefusesStillAdjacent(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "agent-migrate-adj@example.com")
	trip := migrateLegsFixture(t, owner.ID)
	id := addBookedManualTodo(t, ownerToken, trip.ID.String(), "Gothenburg", "Naples")

	s, _ := testPlanSession(true, owner.ID)
	msg, isErr := runMigrateBookingTodoTool(s, json.RawMessage(
		`{"trip_id":"`+trip.ID.String()+`","todo_id":"`+id+`"}`))
	if !isErr || !strings.Contains(msg, "still matches the route") {
		t.Fatalf("still-adjacent migrate = %q (err=%v)", msg, isErr)
	}
}

func TestMigrateBookingTodoToolBadTodoID(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "agent-migrate-badid@example.com")
	trip := migrateLegsFixture(t, owner.ID)

	s, _ := testPlanSession(true, owner.ID)
	msg, isErr := runMigrateBookingTodoTool(s, json.RawMessage(
		`{"trip_id":"`+trip.ID.String()+`","todo_id":"not-a-uuid"}`))
	if !isErr || !strings.Contains(msg, "not valid") {
		t.Fatalf("bad todo_id = %q (err=%v)", msg, isErr)
	}
}
