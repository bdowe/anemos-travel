package main

// List-row enrichment (item_count / booking_total / booking_booked / shared
// on GET /trips, and the item/booking fields on GET /trips/shared-with-me
// with the viewer boundary). The counts come from laterals in
// ListLatestTripsByOwner / ListLatestCollaboratedTripsForUser — one query
// per list, no N+1 — so these tests pin the wire shape, not the SQL.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"travel-route-planner/store"

	"github.com/google/uuid"
)

func addBookingTodo(t *testing.T, tripID uuid.UUID, key string, booked bool) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	todo, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: tripID, Kind: "transport", TodoKey: key, Title: "Book " + key,
	})
	if err != nil {
		t.Fatalf("addBookingTodo(%s): %v", key, err)
	}
	if booked {
		if _, err := q.SetBookingTodoBooked(ctx, store.SetBookingTodoBookedParams{
			ID: todo.ID, TripID: tripID, Booked: true,
		}); err != nil {
			t.Fatalf("SetBookingTodoBooked(%s): %v", key, err)
		}
	}
}

func listTrips(t *testing.T, path, token string) []map[string]any {
	t.Helper()
	rec := doJSON(t, "GET", path, token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s = %d: %s", path, rec.Code, rec.Body.String())
	}
	var trips []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &trips); err != nil {
		t.Fatalf("decode %s: %v (%s)", path, err, rec.Body.String())
	}
	return trips
}

func numField(row map[string]any, key string) (float64, bool) {
	v, ok := row[key].(float64)
	return v, ok
}

func TestTripListEnrichment(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 3)
	addBookingTodo(t, trip.ID, "flight-out", true)
	addBookingTodo(t, trip.ID, "stay-athens", false)

	rows := listTrips(t, "/api/v1/trips", ownerToken)
	if len(rows) != 1 {
		t.Fatalf("list rows = %d, want 1", len(rows))
	}
	row := rows[0]
	for key, want := range map[string]float64{
		"item_count": 3, "booking_total": 2, "booking_booked": 1,
	} {
		if got, ok := numField(row, key); !ok || got != want {
			t.Fatalf("%s = %v, want %v (%v)", key, row[key], want, row)
		}
	}
	// No collaborators yet: shared is false, so omitempty drops it.
	if v, present := row["shared"]; present && v != false {
		t.Fatalf("shared = %v before any collaborator, want absent/false", v)
	}

	// An editor joining flips shared on the owner's list row.
	_, editorToken := createTestUser(t, "editor@example.com")
	shareToken := createShare(t, ownerToken, trip.ID.String(), "editor")
	if rec := joinShare(t, editorToken, shareToken); rec.Code != http.StatusOK {
		t.Fatalf("join share = %d: %s", rec.Code, rec.Body.String())
	}
	row = listTrips(t, "/api/v1/trips", ownerToken)[0]
	if row["shared"] != true {
		t.Fatalf("shared = %v after editor join, want true", row["shared"])
	}
}

func TestTripListZeroBookingProgressStillSerializes(t *testing.T) {
	// The pointer fields exist so a real zero survives omitempty — a trip
	// with todos but nothing booked must say 0, not vanish.
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	addBookingTodo(t, trip.ID, "flight-out", false)

	row := listTrips(t, "/api/v1/trips", ownerToken)[0]
	if got, ok := numField(row, "booking_booked"); !ok || got != 0 {
		t.Fatalf("booking_booked = %v, want explicit 0", row["booking_booked"])
	}
	if got, ok := numField(row, "booking_total"); !ok || got != 1 {
		t.Fatalf("booking_total = %v, want 1", row["booking_total"])
	}
}

func TestSharedWithMeEnrichmentViewerBoundary(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	addBookingTodo(t, trip.ID, "flight-out", true)

	join := func(email, role string) string {
		_, token := createTestUser(t, email)
		shareToken := createShare(t, ownerToken, trip.ID.String(), role)
		var rec *httptest.ResponseRecorder
		if rec = joinShare(t, token, shareToken); rec.Code != http.StatusOK {
			t.Fatalf("join(%s) = %d: %s", role, rec.Code, rec.Body.String())
		}
		return token
	}
	editorToken := join("editor@example.com", "editor")
	viewerToken := join("viewer@example.com", "viewer")

	editorRow := listTrips(t, "/api/v1/trips/shared-with-me", editorToken)[0]
	if got, ok := numField(editorRow, "item_count"); !ok || got != 2 {
		t.Fatalf("editor item_count = %v, want 2", editorRow["item_count"])
	}
	if got, ok := numField(editorRow, "booking_total"); !ok || got != 1 {
		t.Fatalf("editor booking_total = %v, want 1", editorRow["booking_total"])
	}

	viewerRow := listTrips(t, "/api/v1/trips/shared-with-me", viewerToken)[0]
	if got, ok := numField(viewerRow, "item_count"); !ok || got != 2 {
		t.Fatalf("viewer item_count = %v, want 2", viewerRow["item_count"])
	}
	// Booking state is editor-visible only — the getTripHandler boundary.
	for _, key := range []string{"booking_total", "booking_booked"} {
		if v, present := viewerRow[key]; present {
			t.Fatalf("viewer row carries %s = %v, want absent", key, v)
		}
	}
}
