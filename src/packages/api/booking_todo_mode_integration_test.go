package main

import (
	"net/http"
	"strings"
	"testing"
)

// The per-leg mode override (PATCH {mode: ...}): works on auto rows without
// touching booked/auto, rebuilds provider + search_url for the new mode, and
// survives re-syncs the way booked does.

func syncOneTransportTodo(t *testing.T, tripID, token string) map[string]any {
	t.Helper()
	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "transport", "todo_key": "transport:paris>>lyon", "title": "Paris → Lyon",
			"provider": "google_flights", "destination": "Lyon", "origin": "Paris",
			"position": 0, "depart_date": "2026-09-04", "passengers": 1},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	list := decodeTodoList(t, rec)
	if len(list) != 1 {
		t.Fatalf("sync rows = %d, want 1: %v", len(list), list)
	}
	return list[0]
}

func TestSetBookingTodoModeOnAutoRow(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	todo := syncOneTransportTodo(t, tripID, token)
	todoID := todo["id"].(string)
	if todo["mode"] != nil {
		t.Fatalf("fresh derived row must have no mode: %v", todo)
	}

	// Ground override: provider + link flip to Rome2Rio; auto/booked untouched.
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID, token, map[string]any{
		"mode": "train", "origin": "Paris", "destination": "Lyon",
		"depart_date": "2026-09-04", "passengers": 1,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("set mode = %d: %s", rec.Code, rec.Body.String())
	}
	got := decode(t, rec)
	if got["mode"] != "train" || got["provider"] != "rome2rio" {
		t.Fatalf("mode/provider wrong: %v", got)
	}
	if u, _ := got["search_url"].(string); !strings.Contains(u, "rome2rio") {
		t.Fatalf("search_url not rebuilt for ground mode: %v", got["search_url"])
	}
	if got["auto"] != true || got["booked"] != false {
		t.Fatalf("mode change must not touch auto/booked: %v", got)
	}

	// Ferry override: keeps the ferry provider (no ferry entry exists in the
	// transport provider list, so the old fallback stored google_flights) and
	// links to Ferryhopper.
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID, token, map[string]any{
		"mode": "ferry", "origin": "Athens", "destination": "Santorini",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("set ferry mode = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, rec)
	if got["mode"] != "ferry" || got["provider"] != "ferry" {
		t.Fatalf("ferry override wrong: %v", got)
	}
	if u, _ := got["search_url"].(string); !strings.Contains(u, "ferryhopper.com") {
		t.Fatalf("ferry search_url not a Ferryhopper link: %v", got["search_url"])
	}
}

func TestSetBookingTodoModeValidation(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	todo := syncOneTransportTodo(t, tripID, token)
	todoID := todo["id"].(string)

	for name, body := range map[string]map[string]any{
		"invalid mode":       {"mode": "teleport", "origin": "Paris", "destination": "Lyon"},
		"mixed not per-leg":  {"mode": "mixed", "origin": "Paris", "destination": "Lyon"},
		"missing origin":     {"mode": "train", "destination": "Lyon"},
		"combined with edit": {"mode": "train", "origin": "Paris", "destination": "Lyon", "title": "X"},
		"combined w/ booked": {"mode": "train", "origin": "Paris", "destination": "Lyon", "booked": true},
	} {
		rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID, token, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s = %d, want 400: %s", name, rec.Code, rec.Body.String())
		}
	}

	// A stay row is not a leg: the transport-only WHERE yields the shared 404.
	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "transport", "todo_key": "transport:paris>>lyon", "title": "Paris → Lyon",
			"destination": "Lyon", "origin": "Paris", "position": 0, "passengers": 1},
		{"kind": "stay", "todo_key": "stay:lyon", "title": "Stay in Lyon",
			"destination": "Lyon", "position": 1, "guests": 1},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	var stayID string
	for _, row := range decodeTodoList(t, rec) {
		if row["kind"] == "stay" {
			stayID = row["id"].(string)
		}
	}
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+stayID, token, map[string]any{
		"mode": "train", "origin": "Paris", "destination": "Lyon",
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("mode on stay = %d, want 404: %s", rec.Code, rec.Body.String())
	}
}

func TestSyncPreservesModeOverride(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	todo := syncOneTransportTodo(t, tripID, token)
	todoID := todo["id"].(string)
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID, token, map[string]any{
		"mode": "train", "origin": "Paris", "destination": "Lyon",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("set mode = %d: %s", rec.Code, rec.Body.String())
	}

	// An override-aware client re-sync echoes the override's provider; mode
	// must ride through the upsert untouched (same contract as booked).
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "transport", "todo_key": "transport:paris>>lyon", "title": "Paris → Lyon",
			"provider": "rome2rio", "destination": "Lyon", "origin": "Paris",
			"position": 0, "depart_date": "2026-09-04", "passengers": 1},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("re-sync = %d: %s", rec.Code, rec.Body.String())
	}
	list := decodeTodoList(t, rec)
	if len(list) != 1 || list[0]["id"] != todoID {
		t.Fatalf("re-sync replaced the row: %v", list)
	}
	if list[0]["mode"] != "train" || list[0]["provider"] != "rome2rio" {
		t.Fatalf("mode override lost on re-sync: %v", list[0])
	}

	// Even a stale client that still sends the flight default cannot clobber
	// mode itself (provider drifts until the next new-client sync — accepted).
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "transport", "todo_key": "transport:paris>>lyon", "title": "Paris → Lyon",
			"provider": "google_flights", "destination": "Lyon", "origin": "Paris",
			"position": 0, "passengers": 1},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("stale sync = %d: %s", rec.Code, rec.Body.String())
	}
	if list := decodeTodoList(t, rec); list[0]["mode"] != "train" {
		t.Fatalf("stale client clobbered mode: %v", list[0])
	}
}

// Derived Greek-ferry legs send provider "ferry"; the transport provider list
// has no ferry entry, so pickProviderLink's fallback used to silently store
// google_flights. The sync must keep the ferry provider + Ferryhopper link.
func TestSyncKeepsFerryProvider(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, []map[string]any{
		{"kind": "transport", "todo_key": "transport:santorini>>mykonos", "title": "Santorini → Mykonos",
			"provider": "ferry", "destination": "Mykonos", "origin": "Santorini",
			"position": 0, "depart_date": "2026-09-04", "passengers": 1},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	list := decodeTodoList(t, rec)
	if len(list) != 1 || list[0]["provider"] != "ferry" {
		t.Fatalf("ferry provider not preserved: %v", list)
	}
	if u, _ := list[0]["search_url"].(string); !strings.Contains(u, "ferryhopper.com") {
		t.Fatalf("ferry search_url not a Ferryhopper link: %v", list[0]["search_url"])
	}
}
