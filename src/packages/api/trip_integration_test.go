package main

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestTripOwnerCRUD(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)

	get := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil)
	if get.Code != http.StatusOK {
		t.Fatalf("owner GET = %d: %s", get.Code, get.Body.String())
	}

	// Stale-client compat pin (specs/retire-trip-status): a PATCH that still
	// sends the retired status field must succeed — the unknown key is
	// ignored — and the response must not carry a status field.
	patch := doJSON(t, "PATCH", "/api/v1/trips/"+trip.ID.String(), token, map[string]any{
		"status": "planned",
	})
	if patch.Code != http.StatusOK {
		t.Fatalf("owner PATCH = %d: %s", patch.Code, patch.Body.String())
	}
	var patched map[string]any
	if err := json.Unmarshal(patch.Body.Bytes(), &patched); err != nil {
		t.Fatalf("decode PATCH response: %v", err)
	}
	if _, ok := patched["status"]; ok {
		t.Fatalf("trip response still carries retired status field: %s", patch.Body.String())
	}

	del := doJSON(t, "DELETE", "/api/v1/trips/"+trip.ID.String(), token, nil)
	if del.Code != http.StatusNoContent && del.Code != http.StatusOK {
		t.Fatalf("owner DELETE = %d", del.Code)
	}
	if again := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil); again.Code != http.StatusNotFound {
		t.Fatalf("GET after delete = %d, want 404", again.Code)
	}
}

// Cross-user access must 404 (not 403) so trip existence never leaks.
func TestTripOwnershipIsolation(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "owner@example.com")
	_, intruderToken := createTestUser(t, "intruder@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	path := "/api/v1/trips/" + trip.ID.String()

	for _, tc := range []struct {
		method string
		body   any
	}{
		{"GET", nil},
		{"PATCH", map[string]any{"title": "Hijacked"}},
		{"DELETE", nil},
	} {
		if rec := doJSON(t, tc.method, path, intruderToken, tc.body); rec.Code != http.StatusNotFound {
			t.Fatalf("intruder %s = %d, want 404", tc.method, rec.Code)
		}
	}
}

func TestTripListFiltersToCaller(t *testing.T) {
	resetDB(t)
	a, tokenA := createTestUser(t, "a@example.com")
	b, _ := createTestUser(t, "b@example.com")
	createTestTrip(t, a.ID, 1)
	createTestTrip(t, b.ID, 1)
	createTestTrip(t, b.ID, 1)

	rec := doJSON(t, "GET", "/api/v1/trips", tokenA, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list = %d", rec.Code)
	}
	var trips []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &trips); err != nil {
		t.Fatalf("decode trips list: %v (%s)", err, rec.Body.String())
	}
	if len(trips) != 1 {
		t.Fatalf("user A sees %d trips, want 1 (own only)", len(trips))
	}
}

func TestTripListRequiresAuth(t *testing.T) {
	resetDB(t)
	if rec := doJSON(t, "GET", "/api/v1/trips", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous /trips = %d, want 401", rec.Code)
	}
}

func TestTripPatchValidation(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	rec := doJSON(t, "PATCH", "/api/v1/trips/"+trip.ID.String(), token, map[string]any{
		"start_date": "08/01/2026",
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid start_date = %d, want 400", rec.Code)
	}
}

func TestTripPatchTravelMode(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	path := "/api/v1/trips/" + trip.ID.String()

	rec := doJSON(t, "PATCH", path, token, map[string]any{"travel_mode": "car"})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH travel_mode = %d: %s", rec.Code, rec.Body.String())
	}
	var resp TripResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.TravelMode == nil || *resp.TravelMode != "car" {
		t.Fatalf("travel_mode = %v, want car", resp.TravelMode)
	}

	// A later PATCH that omits travel_mode must not clear it.
	rec = doJSON(t, "PATCH", path, token, map[string]any{"title": "Renamed"})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH title = %d: %s", rec.Code, rec.Body.String())
	}
	resp = TripResponse{}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.TravelMode == nil || *resp.TravelMode != "car" {
		t.Fatalf("travel_mode after unrelated PATCH = %v, want car", resp.TravelMode)
	}

	if rec := doJSON(t, "PATCH", path, token, map[string]any{"travel_mode": "teleport"}); rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid travel_mode = %d, want 400", rec.Code)
	}
}
