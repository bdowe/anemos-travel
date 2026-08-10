package main

import (
	"context"
	"net/http"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

func TestItemOwnerCRUDAndReorder(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 3)
	base := "/api/v1/trips/" + trip.ID.String()

	add := doJSON(t, "POST", base+"/items", token, map[string]any{
		"name": "New Stop", "latitude": 37.99, "longitude": 23.74, "category": "restaurant",
	})
	if add.Code != http.StatusCreated && add.Code != http.StatusOK {
		t.Fatalf("add = %d: %s", add.Code, add.Body.String())
	}
	// The add response is the whole updated trip; find the new item's id in
	// the store by its name.
	var newID string
	created, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range created {
		if it.Name == "New Stop" {
			newID = it.ID.String()
		}
	}
	if newID == "" {
		t.Fatalf("added item not found in store; add response: %s", add.Body.String())
	}

	patch := doJSON(t, "PATCH", base+"/items/"+newID, token, map[string]any{"name": "Renamed Stop"})
	if patch.Code != http.StatusOK {
		t.Fatalf("patch = %d: %s", patch.Code, patch.Body.String())
	}

	// Reorder: reverse the full item list.
	items, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(items))
	for i := len(items) - 1; i >= 0; i-- {
		ids = append(ids, items[i].ID.String())
	}
	reorder := doJSON(t, "PUT", base+"/items/order", token, map[string]any{"item_ids": ids})
	if reorder.Code != http.StatusOK && reorder.Code != http.StatusNoContent {
		t.Fatalf("reorder = %d: %s", reorder.Code, reorder.Body.String())
	}
	after, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(ids) {
		t.Fatalf("reorder changed item count: %d, want %d", len(after), len(ids))
	}
	// Every item must sit exactly where the submitted order put it (the batch
	// UPDATE assigns positions 0..n-1 in list order).
	for i, it := range after {
		if it.ID.String() != ids[i] {
			t.Fatalf("reorder not applied at %d: item %s, want %s", i, it.ID, ids[i])
		}
		if it.Position != int32(i) {
			t.Fatalf("item %s position = %d, want %d", it.ID, it.Position, i)
		}
	}

	del := doJSON(t, "DELETE", base+"/items/"+newID, token, nil)
	if del.Code != http.StatusNoContent && del.Code != http.StatusOK {
		t.Fatalf("delete = %d", del.Code)
	}
}

func TestItemCrossUserIsolation(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	_, intruderToken := createTestUser(t, "intruder@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	base := "/api/v1/trips/" + trip.ID.String()

	items, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	itemID := items[0].ID.String()

	cases := []struct {
		method, path string
		body         any
	}{
		{"POST", base + "/items", map[string]any{"name": "X", "latitude": 1.0, "longitude": 1.0}},
		{"PATCH", base + "/items/" + itemID, map[string]any{"name": "Hijack"}},
		{"DELETE", base + "/items/" + itemID, nil},
		{"PUT", base + "/items/order", map[string]any{"item_ids": []string{itemID}}},
	}
	for _, tc := range cases {
		if rec := doJSON(t, tc.method, tc.path, intruderToken, tc.body); rec.Code != http.StatusNotFound {
			t.Fatalf("intruder %s %s = %d, want 404", tc.method, tc.path, rec.Code)
		}
	}

	// Sanity: the owner still can.
	if rec := doJSON(t, "PATCH", base+"/items/"+itemID, ownerToken, map[string]any{"name": "Mine"}); rec.Code != http.StatusOK {
		t.Fatalf("owner patch after intrusion attempts = %d", rec.Code)
	}
}

// Local-source attribution snapshots on the public create path
// (specs/add-to-itinerary): persisted verbatim, returned on reads, optional,
// UUID-shape-validated but never existence-checked.
func TestItemCreateWithLocalSnapshots(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	base := "/api/v1/trips/" + trip.ID.String()

	// The id deliberately does not exist in local_recommendations — snapshots
	// survive pin archival by design, so a dangling UUID must be accepted.
	recID := uuid.NewString()
	add := doJSON(t, "POST", base+"/items", token, map[string]any{
		"name": "Tasca da Ana", "latitude": 38.71, "longitude": -9.14,
		"city": "Lisbon", "category": "restaurant",
		"local_source_name":       "Ana",
		"local_recommendation_id": recID,
	})
	if add.Code != http.StatusCreated {
		t.Fatalf("add = %d: %s", add.Code, add.Body.String())
	}

	// Persisted in the store row.
	items, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, it := range items {
		if it.Name != "Tasca da Ana" {
			continue
		}
		found = true
		if it.LocalSourceName == nil || *it.LocalSourceName != "Ana" {
			t.Fatalf("stored local_source_name = %v, want Ana", it.LocalSourceName)
		}
		if !it.LocalRecommendationID.Valid || uuid.UUID(it.LocalRecommendationID.Bytes).String() != recID {
			t.Fatalf("stored local_recommendation_id = %v, want %s", it.LocalRecommendationID, recID)
		}
	}
	if !found {
		t.Fatalf("added item not found in store")
	}

	// Returned on the trip response (both the create response and GET).
	get := doJSON(t, "GET", base, token, nil)
	if get.Code != http.StatusOK {
		t.Fatalf("get trip = %d: %s", get.Code, get.Body.String())
	}
	var foundInResp bool
	for _, raw := range decode(t, get)["items"].([]any) {
		m := raw.(map[string]any)
		if m["name"] != "Tasca da Ana" {
			continue
		}
		foundInResp = true
		if m["local_source_name"] != "Ana" || m["local_recommendation_id"] != recID {
			t.Fatalf("response snapshots = %v / %v, want Ana / %s",
				m["local_source_name"], m["local_recommendation_id"], recID)
		}
	}
	if !foundInResp {
		t.Fatalf("added item missing from trip response: %s", get.Body.String())
	}
}

func TestItemCreateSnapshotsOptionalAndValidated(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()

	// Snapshots absent: item persists with NULLs and the response omits them.
	add := doJSON(t, "POST", base+"/items", token, map[string]any{
		"name": "Plain Stop", "latitude": 1.0, "longitude": 2.0,
	})
	if add.Code != http.StatusCreated {
		t.Fatalf("plain add = %d: %s", add.Code, add.Body.String())
	}
	items, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].LocalSourceName != nil || items[0].LocalRecommendationID.Valid {
		t.Fatalf("plain item grew snapshots: %+v", items[0])
	}

	// Malformed recommendation id: 400, nothing created.
	bad := doJSON(t, "POST", base+"/items", token, map[string]any{
		"name": "Bad Rec", "latitude": 1.0, "longitude": 2.0,
		"local_recommendation_id": "not-a-uuid",
	})
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("malformed rec id = %d, want 400: %s", bad.Code, bad.Body.String())
	}

	// Blank strings are treated as absent, not stored as empties.
	blank := doJSON(t, "POST", base+"/items", token, map[string]any{
		"name": "Blank Snap", "latitude": 1.0, "longitude": 2.0,
		"local_source_name": "  ", "local_recommendation_id": "",
	})
	if blank.Code != http.StatusCreated {
		t.Fatalf("blank snapshots add = %d: %s", blank.Code, blank.Body.String())
	}
	items, err = store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range items {
		if it.Name == "Blank Snap" && (it.LocalSourceName != nil || it.LocalRecommendationID.Valid) {
			t.Fatalf("blank snapshots stored: %+v", it)
		}
	}
}

func TestItemCreateWithSnapshotsForeignTripRejected(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "owner@example.com")
	_, intruderToken := createTestUser(t, "intruder@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	rec := doJSON(t, "POST", "/api/v1/trips/"+trip.ID.String()+"/items", intruderToken, map[string]any{
		"name": "Sneaky", "latitude": 1.0, "longitude": 2.0,
		"local_source_name":       "Ana",
		"local_recommendation_id": uuid.NewString(),
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("foreign trip add = %d, want 404", rec.Code)
	}
	items, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("foreign add persisted: %d items", len(items))
	}
}

func TestItemValidation(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	base := "/api/v1/trips/" + trip.ID.String()

	if rec := doJSON(t, "POST", base+"/items", token, map[string]any{
		"name": "Bad Cat", "latitude": 1.0, "longitude": 1.0, "category": "spaceport",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid category = %d, want 400", rec.Code)
	}
	if rec := doJSON(t, "POST", base+"/items", token, map[string]any{
		"name": "Bad Time", "latitude": 1.0, "longitude": 1.0, "time_of_day": "brunch",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid time_of_day = %d, want 400", rec.Code)
	}

	// A stale/partial reorder list conflicts.
	rec := doJSON(t, "PUT", base+"/items/order", token, map[string]any{"item_ids": []string{}})
	if rec.Code != http.StatusConflict {
		t.Fatalf("stale reorder = %d, want 409", rec.Code)
	}
}
