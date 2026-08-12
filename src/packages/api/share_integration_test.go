package main

import (
	"bytes"
	"context"
	"net/http"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// mustChatID returns the trip's chat lineage id or fails the test.
func mustChatID(t *testing.T, trip store.Trip) *string {
	t.Helper()
	if trip.ChatID == nil || *trip.ChatID == "" {
		t.Fatal("test trip has no chat_id")
	}
	return trip.ChatID
}

// createTestTripInLineage appends a newer trip version to an existing chat
// lineage (what the /plan agent does when it re-creates an itinerary).
func createTestTripInLineage(t *testing.T, owner uuid.UUID, chatID, title string) store.Trip {
	t.Helper()
	trip, err := store.New(dbPool).CreateTrip(context.Background(), store.CreateTripParams{
		UserID: owner, Title: title, ChatID: &chatID,
	})
	if err != nil {
		t.Fatalf("createTestTripInLineage: %v", err)
	}
	return trip
}

func containsCopy(body []byte) bool {
	return bytes.Contains(body, []byte("(copy)"))
}

// createShare mints a share link for the trip and returns its token.
func createShare(t *testing.T, ownerToken, tripID, role string) string {
	t.Helper()
	var body any
	if role != "" {
		body = map[string]any{"role": role}
	}
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/share", ownerToken, body)
	if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Fatalf("create share = %d: %s", rec.Code, rec.Body.String())
	}
	token, _ := decode(t, rec)["token"].(string)
	if token == "" {
		t.Fatal("share response has no token")
	}
	return token
}

func TestSharedTripAnonymousRead(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	shareToken := createShare(t, ownerToken, trip.ID.String(), "")

	rec := doJSON(t, "GET", "/api/v1/shared/"+shareToken, "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("anonymous shared read = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if body["owner_name"] == "" || body["owner_name"] == nil {
		t.Fatal("shared trip missing owner_name")
	}
	tripBody, _ := body["trip"].(map[string]any)
	if tripBody == nil {
		t.Fatalf("shared trip missing trip payload: %s", rec.Body.String())
	}
	// chat_id is the private lineage handle; it must never leak on a share.
	if cid, present := tripBody["chat_id"]; present && cid != nil {
		t.Fatalf("shared trip leaked chat_id: %v", cid)
	}
}

func TestSharedTripUnknownAndRevokedTokens(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	shareToken := createShare(t, ownerToken, trip.ID.String(), "")

	if rec := doJSON(t, "GET", "/api/v1/shared/no-such-token", "", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown token = %d, want 404", rec.Code)
	}

	if rec := doJSON(t, "DELETE", "/api/v1/trips/"+trip.ID.String()+"/share", ownerToken, nil); rec.Code >= 300 {
		t.Fatalf("revoke = %d", rec.Code)
	}
	rec := doJSON(t, "GET", "/api/v1/shared/"+shareToken, "", nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("revoked token = %d, want 404 (same as unknown)", rec.Code)
	}
}

func TestShareNonOwnerCannotMint(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "owner@example.com")
	_, intruderToken := createTestUser(t, "intruder@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	rec := doJSON(t, "POST", "/api/v1/trips/"+trip.ID.String()+"/share", intruderToken, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("non-owner share mint = %d, want 404", rec.Code)
	}
}

func TestSharedTripDuplicate(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	_, copierToken := createTestUser(t, "copier@example.com")
	trip := createTestTrip(t, owner.ID, 3)
	shareToken := createShare(t, ownerToken, trip.ID.String(), "")

	rec := doJSON(t, "POST", "/api/v1/shared/"+shareToken+"/duplicate", copierToken, nil)
	if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Fatalf("duplicate = %d: %s", rec.Code, rec.Body.String())
	}

	list := doJSON(t, "GET", "/api/v1/trips", copierToken, nil)
	if list.Code != http.StatusOK || !containsCopy(list.Body.Bytes()) {
		t.Fatalf("copier's trip list missing the copy: %s", list.Body.String())
	}
}

// The share must resolve the lineage's LATEST version: creating a newer trip
// with the same chat_id retargets existing links.
func TestSharedTripResolvesLatestVersion(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	shareToken := createShare(t, ownerToken, trip.ID.String(), "")

	newer := createTestTripInLineage(t, owner.ID, *mustChatID(t, trip), "Newer Version")

	rec := doJSON(t, "GET", "/api/v1/shared/"+shareToken, "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("shared read = %d", rec.Code)
	}
	tripBody, _ := decode(t, rec)["trip"].(map[string]any)
	if tripBody == nil || tripBody["id"] != newer.ID.String() {
		t.Fatalf("share resolved %v, want latest version %s", tripBody["id"], newer.ID)
	}
}
