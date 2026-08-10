package main

import (
	"context"
	"net/http"
	"testing"

	"travel-route-planner/store"
)

// Table test pinning getTripHandler's per-role response shape: owner, editor
// collaborator, and viewer follow each GET the same trip and must see exactly
// the fields their role allows. The trip carries confirmed + draft (auto)
// accommodations and segments plus a booking todo, so every viewer-conditional
// read branch is exercised. This locks the shape across the read-fanout
// (errgroup) refactor — the concurrency change must be invisible.
func TestGetTripResponseShapeByRole(t *testing.T) {
	resetDB(t)
	ctx := context.Background()
	q := store.New(dbPool)

	owner, ownerToken := createTestUser(t, "owner@example.com")
	editor, editorToken := createTestUser(t, "editor@example.com")
	_, viewerToken := createTestUser(t, "viewer@example.com")
	setDisplayName := func(email, name string) {
		t.Helper()
		if _, err := dbPool.Exec(ctx, `UPDATE users SET display_name = $1 WHERE email = $2`, name, email); err != nil {
			t.Fatalf("setDisplayName(%s): %v", email, err)
		}
	}
	setDisplayName("owner@example.com", "Olive Owner")
	setDisplayName("editor@example.com", "Eddie Editor")

	trip := createTestTrip(t, owner.ID, 2)

	// Confirmed rows all roles must see...
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Confirmed Hotel",
	}); err != nil {
		t.Fatalf("create accommodation: %v", err)
	}
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "train",
	}); err != nil {
		t.Fatalf("create segment: %v", err)
	}
	// ...draft (auto=true) rows only owner/editor may see...
	if _, err := dbPool.Exec(ctx, `INSERT INTO accommodations (trip_id, name, auto, auto_key)
		VALUES ($1, 'Draft Hotel', true, 'stay-key')`, trip.ID); err != nil {
		t.Fatalf("insert draft accommodation: %v", err)
	}
	if _, err := dbPool.Exec(ctx, `INSERT INTO trip_segments (trip_id, mode, auto, auto_key)
		VALUES ($1, 'flight', true, 'seg-key')`, trip.ID); err != nil {
		t.Fatalf("insert draft segment: %v", err)
	}
	// ...and a booking todo, which viewers never see.
	if _, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: trip.ID, Kind: "flight", TodoKey: "todo-key", Title: "Book flight",
	}); err != nil {
		t.Fatalf("create booking todo: %v", err)
	}

	// Editor + viewer join the lineage; the last edit is attributed to the
	// editor so updated_by_name resolution is exercised for every role.
	if rec := joinShare(t, editorToken, createShare(t, ownerToken, trip.ID.String(), "editor")); rec.Code != http.StatusOK {
		t.Fatalf("editor join = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := joinShare(t, viewerToken, createShare(t, ownerToken, trip.ID.String(), "viewer")); rec.Code != http.StatusOK {
		t.Fatalf("viewer join = %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := dbPool.Exec(ctx, `UPDATE trips SET updated_by = $1 WHERE id = $2`, editor.ID, trip.ID); err != nil {
		t.Fatalf("stamp updated_by: %v", err)
	}

	arrLen := func(v any) int {
		arr, _ := v.([]any)
		return len(arr)
	}
	cases := []struct {
		role          string
		token         string
		wantChatID    bool // owner-only: collaborators never get the lineage key
		wantStays     int  // drafts (auto=true) are editor-facing working state
		wantSegments  int
		wantTodos     int  // booking todos are hidden from viewer follows
		wantOwnerName any  // set for collaborators, absent for the owner
		wantUpdatedBy any  // absent for the attributed editor's own view
		wantShared    bool // owner-only freshness-poll hint
	}{
		{role: "owner", token: ownerToken, wantChatID: true, wantStays: 2, wantSegments: 2,
			wantTodos: 1, wantOwnerName: nil, wantUpdatedBy: "Eddie Editor", wantShared: true},
		{role: "editor", token: editorToken, wantChatID: false, wantStays: 2, wantSegments: 2,
			wantTodos: 1, wantOwnerName: "Olive Owner", wantUpdatedBy: nil, wantShared: false},
		{role: "viewer", token: viewerToken, wantChatID: false, wantStays: 1, wantSegments: 1,
			wantTodos: 0, wantOwnerName: "Olive Owner", wantUpdatedBy: "Eddie Editor", wantShared: false},
	}
	for _, tc := range cases {
		t.Run(tc.role, func(t *testing.T) {
			rec := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), tc.token, nil)
			if rec.Code != http.StatusOK {
				t.Fatalf("GET = %d: %s", rec.Code, rec.Body.String())
			}
			body := decode(t, rec)
			// Shared core fields — identical for every role.
			if body["id"] != trip.ID.String() || body["title"] != "Test Trip" {
				t.Fatalf("core fields = %v / %v", body["id"], body["title"])
			}
			if n := arrLen(body["items"]); n != 2 {
				t.Fatalf("items = %d, want 2", n)
			}
			// Role-dependent fields.
			if body["access"] != tc.role {
				t.Fatalf("access = %v, want %s", body["access"], tc.role)
			}
			if got := body["chat_id"] != nil; got != tc.wantChatID {
				t.Fatalf("chat_id present = %v, want %v", got, tc.wantChatID)
			}
			if n := arrLen(body["accommodations"]); n != tc.wantStays {
				t.Fatalf("accommodations = %d, want %d", n, tc.wantStays)
			}
			if n := arrLen(body["segments"]); n != tc.wantSegments {
				t.Fatalf("segments = %d, want %d", n, tc.wantSegments)
			}
			if n := arrLen(body["booking_todos"]); n != tc.wantTodos {
				t.Fatalf("booking_todos = %d, want %d", n, tc.wantTodos)
			}
			if body["owner_name"] != tc.wantOwnerName {
				t.Fatalf("owner_name = %v, want %v", body["owner_name"], tc.wantOwnerName)
			}
			if body["updated_by_name"] != tc.wantUpdatedBy {
				t.Fatalf("updated_by_name = %v, want %v", body["updated_by_name"], tc.wantUpdatedBy)
			}
			if got := body["shared"] == true; got != tc.wantShared {
				t.Fatalf("shared = %v, want %v", body["shared"], tc.wantShared)
			}
		})
	}
}
