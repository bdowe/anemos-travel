package main

import (
	"net/http"
	"testing"
)

// booking_todo_identity_integration_test.go — the outcome contract for
// migration 00064, written against what the traveler keeps rather than against
// the mechanism that keeps it. These assertions must survive the eventual move
// to server-side derivation (specs/server-booking-todos) unchanged.

// homeLegPayload is what _deriveTodos posts for a one-city round trip out of
// `home`: outbound, stay, return — in that construction order.
func homeLegPayload(home, city string) []map[string]any {
	return []map[string]any{
		{"kind": "transport", "todo_key": "transport:" + lower(home) + ">>" + lower(city),
			"title": home + " → " + city, "origin": home, "destination": city,
			"position": 0, "depart_date": "2026-09-01", "passengers": 1},
		{"kind": "stay", "todo_key": "stay:" + lower(city), "title": "Stay in " + city,
			"destination": city, "position": 1, "depart_date": "2026-09-01",
			"return_date": "2026-09-05", "guests": 1},
		{"kind": "transport", "todo_key": "transport:" + lower(city) + ">>" + lower(home),
			"title": city + " → " + home, "origin": city, "destination": home,
			"position": 2, "depart_date": "2026-09-05", "passengers": 1},
	}
}

func lower(s string) string {
	out := []rune(s)
	for i, r := range out {
		if r >= 'A' && r <= 'Z' {
			out[i] = r + 32
		}
	}
	return string(out)
}

// The bug that was live in production: correcting a saved home airport rekeyed
// every home leg the traveler owned, and the prune deleted the old rows —
// taking the booked flag, the per-leg mode override and the linked expense's
// source with them. The row must now survive with its id, because its identity
// no longer contains the airport.
func TestHomeLegSurvivesHomeAirportChange(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()
	base := "/api/v1/trips/" + tripID

	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("save home airport = %d: %s", rec.Code, rec.Body.String())
	}
	rec := doJSON(t, "PUT", base+"/booking-todos", token, homeLegPayload("EWR", "Amsterdam"))
	if rec.Code != http.StatusOK {
		t.Fatalf("first sync = %d: %s", rec.Code, rec.Body.String())
	}
	first := decodeTodoList(t, rec)
	if len(first) != 3 {
		t.Fatalf("first sync rows = %d, want 3: %v", len(first), first)
	}
	// The wire still speaks endpoint-labelled keys, so the client matches on
	// exactly what it derived.
	if first[0]["todo_key"] != "transport:ewr>>amsterdam" || first[2]["todo_key"] != "transport:amsterdam>>ewr" {
		t.Fatalf("wire keys are not the endpoint-labelled ones: %v", first)
	}
	outboundID, returnID := first[0]["id"].(string), first[2]["id"].(string)

	// Everything a traveler can invest in a row: booked, a per-leg mode, and a
	// budget expense linked to it.
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+outboundID, token, map[string]any{"booked": true}); rec.Code != http.StatusOK {
		t.Fatalf("book outbound = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+outboundID, token, map[string]any{
		"mode": "train", "origin": "EWR", "destination": "Amsterdam", "depart_date": "2026-09-01",
	}); rec.Code != http.StatusOK {
		t.Fatalf("set mode = %d: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "POST", base+"/budget/expenses", token, map[string]any{
		"label": "EWR → Amsterdam", "category": "flights", "amount": 344,
		"source_kind": "booking_todo", "source_id": outboundID})
	if rec.Code != http.StatusCreated {
		t.Fatalf("link expense = %d: %s", rec.Code, rec.Body.String())
	}
	expenseID := decode(t, rec)["id"].(string)

	// The traveler corrects their home airport, and the trip page re-derives
	// with the new one — the exact sequence that used to destroy the row.
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "ALB"}); rec.Code != http.StatusOK {
		t.Fatalf("change home airport = %d: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "PUT", base+"/booking-todos", token, homeLegPayload("ALB", "Amsterdam"))
	if rec.Code != http.StatusOK {
		t.Fatalf("resync = %d: %s", rec.Code, rec.Body.String())
	}
	after := decodeTodoList(t, rec)
	if len(after) != 3 {
		t.Fatalf("resync rows = %d, want 3 (a duplicate means the rename split the row): %v", len(after), after)
	}
	if after[0]["id"] != outboundID {
		t.Fatalf("outbound row was replaced: %v", after[0])
	}
	if after[2]["id"] != returnID {
		t.Fatalf("return row was replaced: %v", after[2])
	}
	if after[0]["booked"] != true {
		t.Fatalf("booked flag lost: %v", after[0])
	}
	if after[0]["mode"] != "train" {
		t.Fatalf("per-leg mode lost: %v", after[0])
	}
	// The labels followed the airport, so the traveler sees the right leg.
	if after[0]["title"] != "ALB → Amsterdam" || after[2]["title"] != "Amsterdam → ALB" {
		t.Fatalf("titles did not follow the new airport: %v / %v", after[0]["title"], after[2]["title"])
	}
	if after[0]["todo_key"] != "transport:alb>>amsterdam" {
		t.Fatalf("wire key did not follow the new airport: %v", after[0])
	}
	// And the money is still attached to a row that exists.
	rec = doJSON(t, "GET", base+"/budget/expenses", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list expenses = %d", rec.Code)
	}
	var found bool
	for _, e := range decodeList(t, rec) {
		if e["id"] == expenseID {
			found = true
			if e["source_id"] != outboundID {
				t.Fatalf("expense link points at a different row now: %v", e)
			}
		}
	}
	if !found {
		t.Fatalf("linked expense vanished: %s", rec.Body.String())
	}
}

// A trip that leaves from one airport and comes home into another: the two
// legs are distinct rows, and moving one must not disturb the other.
func TestAsymmetricHomeLegsAreIndependent(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()

	payload := homeLegPayload("EWR", "Amsterdam")
	rec := doJSON(t, "PUT", base+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("first sync = %d: %s", rec.Code, rec.Body.String())
	}
	first := decodeTodoList(t, rec)
	outboundID, returnID := first[0]["id"].(string), first[2]["id"].(string)
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+returnID, token, map[string]any{"booked": true}); rec.Code != http.StatusOK {
		t.Fatalf("book return = %d: %s", rec.Code, rec.Body.String())
	}

	// Only the departure moves to ALB; the return still comes home into EWR.
	payload[0]["todo_key"] = "transport:alb>>amsterdam"
	payload[0]["title"] = "ALB → Amsterdam"
	payload[0]["origin"] = "ALB"
	rec = doJSON(t, "PUT", base+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("resync = %d: %s", rec.Code, rec.Body.String())
	}
	after := decodeTodoList(t, rec)
	if len(after) != 3 {
		t.Fatalf("resync rows = %d, want 3: %v", len(after), after)
	}
	if after[0]["id"] != outboundID || after[0]["title"] != "ALB → Amsterdam" {
		t.Fatalf("outbound did not move in place: %v", after[0])
	}
	if after[2]["id"] != returnID || after[2]["title"] != "Amsterdam → EWR" || after[2]["booked"] != true {
		t.Fatalf("return leg was disturbed by a departure-only change: %v", after[2])
	}
}

// A row the traveler has invested in is never destroyed by the prune. It leaves
// the derived set — auto:false — and lands in the residual "Other bookings"
// list, where it can be edited or removed. Untouched rows are still deleted.
func TestStalePruneDemotesInvestedRowsAndDeletesTheRest(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()

	payload := []map[string]any{
		{"kind": "stay", "todo_key": "stay:paris", "title": "Stay in Paris",
			"destination": "Paris", "position": 0, "guests": 1},
		{"kind": "stay", "todo_key": "stay:lyon", "title": "Stay in Lyon",
			"destination": "Lyon", "position": 1, "guests": 1},
	}
	rec := doJSON(t, "PUT", base+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("first sync = %d: %s", rec.Code, rec.Body.String())
	}
	first := decodeTodoList(t, rec)
	parisID := first[0]["id"].(string)
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+parisID, token, map[string]any{"booked": true}); rec.Code != http.StatusOK {
		t.Fatalf("book Paris = %d: %s", rec.Code, rec.Body.String())
	}

	// Both cities leave the itinerary. Paris was booked; Lyon was not.
	rec = doJSON(t, "PUT", base+"/booking-todos", token, []map[string]any{})
	if rec.Code != http.StatusOK {
		t.Fatalf("prune sync = %d: %s", rec.Code, rec.Body.String())
	}
	after := decodeTodoList(t, rec)
	if len(after) != 1 {
		t.Fatalf("rows after prune = %d, want 1 (booked survives, untouched is deleted): %v", len(after), after)
	}
	if after[0]["id"] != parisID {
		t.Fatalf("the wrong row survived: %v", after[0])
	}
	if after[0]["booked"] != true {
		t.Fatalf("survivor lost its booked flag: %v", after[0])
	}
	if after[0]["auto"] != false {
		t.Fatalf("survivor must be demoted to manual so it stops being re-derived and can be removed: %v", after[0])
	}
	// Demoted means the traveler can now delete it — an auto row cannot be.
	if rec := doJSON(t, "DELETE", base+"/booking-todos/"+parisID, token, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete demoted row = %d: %s", rec.Code, rec.Body.String())
	}
}
