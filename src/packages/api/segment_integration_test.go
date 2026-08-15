package main

import (
	"context"
	"net/http"
	"testing"

	"travel-route-planner/store"
)

// Segment CRUD + input-validation coverage. Mirrors the accommodation/booking
// integration tests: create trip → add → patch → list → delete, plus the
// negative-input rejections added in the hardening sweep.

func TestSegmentOwnerCRUD(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()

	// Add a valid segment.
	add := doJSON(t, "POST", base+"/segments", token, map[string]any{
		"mode": "train", "origin": "Athens", "destination": "Thessaloniki",
		"depart_date": "2026-08-01", "provider": "Hellenic Train",
		"price_note": "~40 EUR", "notes": "book aisle seat",
	})
	if add.Code != http.StatusCreated {
		t.Fatalf("add = %d: %s", add.Code, add.Body.String())
	}
	created := decode(t, add)
	segID := created["id"].(string)
	if created["mode"] != "train" || created["origin"] != "Athens" {
		t.Fatalf("created segment = %v", created)
	}

	// Patch it (edit confirms the row; content updates apply).
	patch := doJSON(t, "PATCH", base+"/segments/"+segID, token, map[string]any{
		"mode": "bus", "destination": "Meteora", "notes": "day trip",
	})
	if patch.Code != http.StatusOK {
		t.Fatalf("patch = %d: %s", patch.Code, patch.Body.String())
	}
	if got := decode(t, patch); got["mode"] != "bus" || got["destination"] != "Meteora" {
		t.Fatalf("patched segment = %v", got)
	}

	// List (via the trip GET) shows the segment.
	segs, err := store.New(dbPool).ListSegmentsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(segs) != 1 {
		t.Fatalf("want 1 segment, got %d", len(segs))
	}

	// Delete.
	del := doJSON(t, "DELETE", base+"/segments/"+segID, token, nil)
	if del.Code != http.StatusNoContent {
		t.Fatalf("delete = %d: %s", del.Code, del.Body.String())
	}
	segs, err = store.New(dbPool).ListSegmentsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(segs) != 0 {
		t.Fatalf("segment survived delete: %d", len(segs))
	}
}

func TestSegmentCrossUserIsolation(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	_, intruderToken := createTestUser(t, "intruder@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()

	add := doJSON(t, "POST", base+"/segments", ownerToken, map[string]any{
		"mode": "flight", "origin": "JFK", "destination": "CDG",
	})
	if add.Code != http.StatusCreated {
		t.Fatalf("owner add = %d: %s", add.Code, add.Body.String())
	}
	segID := decode(t, add)["id"].(string)

	cases := []struct {
		method, path string
		body         any
	}{
		{"POST", base + "/segments", map[string]any{"mode": "train", "origin": "A", "destination": "B"}},
		{"PATCH", base + "/segments/" + segID, map[string]any{"mode": "bus"}},
		{"DELETE", base + "/segments/" + segID, nil},
	}
	for _, tc := range cases {
		if rec := doJSON(t, tc.method, tc.path, intruderToken, tc.body); rec.Code != http.StatusNotFound {
			t.Fatalf("intruder %s %s = %d, want 404", tc.method, tc.path, rec.Code)
		}
	}
}

func TestSegmentValidation(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()

	// Bad mode → 400.
	if rec := doJSON(t, "POST", base+"/segments", token, map[string]any{
		"mode": "teleport", "origin": "A", "destination": "B",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad mode = %d, want 400", rec.Code)
	}

	// An arrival before its departure → 400 on create AND on edit. This is the
	// guard the agent's add_transport_segment mirrors; the two must agree, or
	// a pair the traveler's own sheet refuses could still arrive via chat.
	if rec := doJSON(t, "POST", base+"/segments", token, map[string]any{
		"mode": "flight", "origin": "EWR", "destination": "Amsterdam",
		"depart_date": "2026-08-24", "arrive_date": "2026-08-23",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("backwards arrive_date = %d, want 400: %s", rec.Code, rec.Body.String())
	}

	// Oversized notes (5 MB) → rejected, nothing persisted. notes is the biggest
	// sink. A body this large is stopped by the 256 KiB body-limit middleware
	// (413) before reaching the handler; a smaller-but-still-over-cap notes
	// (below) exercises the handler's own boundedOptional check (400).
	huge := make([]byte, 5<<20)
	for i := range huge {
		huge[i] = 'x'
	}
	if rec := doJSON(t, "POST", base+"/segments", token, map[string]any{
		"mode": "train", "origin": "A", "destination": "B", "notes": string(huge),
	}); rec.Code != http.StatusRequestEntityTooLarge && rec.Code != http.StatusBadRequest {
		t.Fatalf("oversized notes = %d, want 413 or 400: %s", rec.Code, rec.Body.String())
	}

	// Over-cap notes that fits under the body limit → the handler's own 400.
	overCap := make([]byte, maxNoteLen+1)
	for i := range overCap {
		overCap[i] = 'x'
	}
	if rec := doJSON(t, "POST", base+"/segments", token, map[string]any{
		"mode": "train", "origin": "A", "destination": "B", "notes": string(overCap),
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("over-cap notes = %d, want 400: %s", rec.Code, rec.Body.String())
	}

	// Over-length origin → 400.
	longOrigin := make([]byte, maxNameLen+1)
	for i := range longOrigin {
		longOrigin[i] = 'a'
	}
	if rec := doJSON(t, "POST", base+"/segments", token, map[string]any{
		"mode": "train", "origin": string(longOrigin), "destination": "B",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("over-length origin = %d, want 400", rec.Code)
	}

	segs, err := store.New(dbPool).ListSegmentsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(segs) != 0 {
		t.Fatalf("rejected segments persisted: %d", len(segs))
	}
}

// An overnight leg — depart Aug 23, arrive Aug 24 — is the whole point of
// trip_segments carrying two dates. It round-trips, and a partial PATCH cannot
// leave the pair backwards: UpdateSegment COALESCEs each date, so validating
// only what the REQUEST carries would let "arrive 08-22" land on a row that
// departs 08-23. The trip page renders a known pair as a span, so that is a
// nonsense row on screen, not a cosmetic one.
func TestSegmentOvernightPairRoundTripsAndStaysOrdered(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()

	rec := doJSON(t, "POST", base+"/segments", token, map[string]any{
		"mode": "flight", "origin": "EWR", "destination": "Amsterdam",
		"depart_date": "2026-08-23", "arrive_date": "2026-08-24",
	})
	if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Fatalf("overnight segment = %d: %s", rec.Code, rec.Body.String())
	}
	created := decode(t, rec)
	if created["depart_date"] != "2026-08-23" || created["arrive_date"] != "2026-08-24" {
		t.Fatalf("overnight pair not echoed: %s", rec.Body.String())
	}
	segID, _ := created["id"].(string)

	// Arrival alone, moved before the STORED departure → 400.
	if rec := doJSON(t, "PATCH", base+"/segments/"+segID, token, map[string]any{
		"arrive_date": "2026-08-22",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("backwards arrive_date on PATCH = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	// Departure alone, moved after the STORED arrival → 400, the mirror case.
	if rec := doJSON(t, "PATCH", base+"/segments/"+segID, token, map[string]any{
		"depart_date": "2026-08-26",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("depart_date past stored arrival = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	// A legitimate partial edit still works, and keeps the other date.
	rec = doJSON(t, "PATCH", base+"/segments/"+segID, token, map[string]any{
		"depart_date": "2026-08-22",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("valid partial edit = %d: %s", rec.Code, rec.Body.String())
	}
	if got := decode(t, rec); got["arrive_date"] != "2026-08-24" {
		t.Fatalf("partial edit dropped the arrival: %s", rec.Body.String())
	}
}
