package main

import (
	"net/http"
	"testing"
)

// The derived-todo sync path (PUT /booking-todos), now a single batch upsert:
// re-syncs must be idempotent (no duplicate rows), preserve the booked flag,
// and still apply content/position changes from the new payload.
func TestSyncBookingTodosPreservesBookedAcrossResyncs(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	payload := []map[string]any{
		{"kind": "stay", "todo_key": "stay:paris", "title": "Stay in Paris",
			"subtitle": "3 nights", "destination": "Paris", "position": 0,
			"depart_date": "2026-09-01", "return_date": "2026-09-04", "guests": 2},
		{"kind": "transport", "todo_key": "leg:paris-lyon", "title": "Paris → Lyon",
			"destination": "Lyon", "origin": "Paris", "position": 1,
			"depart_date": "2026-09-04", "passengers": 2},
	}

	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("first sync = %d: %s", rec.Code, rec.Body.String())
	}
	first := decodeTodoList(t, rec)
	if len(first) != 2 {
		t.Fatalf("first sync rows = %d, want 2: %s", len(first), rec.Body.String())
	}
	stayID := first[0]["id"].(string)
	if first[0]["todo_key"] != "stay:paris" || first[0]["booked"] != false ||
		first[0]["auto"] != true || first[0]["subtitle"] != "3 nights" {
		t.Fatalf("first stay row wrong: %v", first[0])
	}
	if first[1]["subtitle"] != nil {
		t.Fatalf("omitted subtitle must stay null, got %v", first[1]["subtitle"])
	}
	if u, _ := first[0]["search_url"].(string); u == "" {
		t.Fatalf("stay search_url not built: %v", first[0])
	}

	// Identical re-sync: same rows, same ids, still no duplicates.
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("second sync = %d: %s", rec.Code, rec.Body.String())
	}
	second := decodeTodoList(t, rec)
	if len(second) != 2 || second[0]["id"] != stayID {
		t.Fatalf("re-sync duplicated or replaced rows: %v", second)
	}

	// Book the stay, then sync again — the flag must survive the upsert.
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+stayID, token, map[string]any{"booked": true})
	if rec.Code != http.StatusOK || decode(t, rec)["booked"] != true {
		t.Fatalf("book stay = %d: %s", rec.Code, rec.Body.String())
	}
	// The new payload also moves the stay and rewrites its subtitle, proving
	// content columns still update while booked is preserved.
	payload[0]["subtitle"] = "4 nights"
	payload[0]["position"] = 1
	payload[1]["position"] = 0
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("third sync = %d: %s", rec.Code, rec.Body.String())
	}
	third := decodeTodoList(t, rec)
	if len(third) != 2 {
		t.Fatalf("third sync rows = %d, want 2: %v", len(third), third)
	}
	// Order comes back by position: transport first now.
	if third[0]["todo_key"] != "leg:paris-lyon" || third[1]["id"] != stayID {
		t.Fatalf("re-synced positions not applied: %v", third)
	}
	if third[1]["booked"] != true {
		t.Fatalf("booked flag lost on re-sync: %v", third[1])
	}
	if third[1]["subtitle"] != "4 nights" {
		t.Fatalf("content update lost on re-sync: %v", third[1])
	}

	// Dropping a leg from the payload prunes its auto row.
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, payload[:1])
	if rec.Code != http.StatusOK {
		t.Fatalf("prune sync = %d: %s", rec.Code, rec.Body.String())
	}
	if pruned := decodeTodoList(t, rec); len(pruned) != 1 || pruned[0]["id"] != stayID {
		t.Fatalf("stale auto todo not pruned: %v", pruned)
	}
}

// A payload repeating a todo_key must collapse last-wins — the same final
// state the old sequential per-row upserts produced.
func TestSyncBookingTodosDuplicateKeyLastWins(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "stay", "todo_key": "stay:rome", "title": "First title", "destination": "Rome", "position": 0},
		{"kind": "stay", "todo_key": "stay:rome", "title": "Second title", "destination": "Rome", "position": 3},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	list := decodeTodoList(t, rec)
	if len(list) != 1 {
		t.Fatalf("duplicate key rows = %d, want 1: %v", len(list), list)
	}
	if list[0]["title"] != "Second title" || int(list[0]["position"].(float64)) != 3 {
		t.Fatalf("last occurrence did not win: %v", list[0])
	}
}
