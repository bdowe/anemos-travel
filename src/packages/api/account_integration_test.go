package main

import (
	"net/http"
	"testing"

	"travel-route-planner/store"
)

func TestAccountDisplayNameUpdate(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "me@example.com")

	rec := doJSON(t, "PATCH", "/api/v1/auth/account", token, map[string]any{
		"display_name": "Brian D",
	})
	if rec.Code != http.StatusOK || decode(t, rec)["display_name"] != "Brian D" {
		t.Fatalf("patch = %d: %s", rec.Code, rec.Body.String())
	}

	if rec := doJSON(t, "PATCH", "/api/v1/auth/account", token, map[string]any{
		"display_name": "   ",
	}); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("blank name = %d, want 422", rec.Code)
	}
}

// The client syncs its resolved locale here so background email (which has no
// request to negotiate from) knows what language to write in.
func TestAccountLocaleRoundTrip(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "me@example.com")

	// Never-set locale is absent rather than an empty string.
	if _, present := decode(t, doJSON(t, "GET", "/api/v1/auth/me", token, nil))["locale"]; present {
		t.Fatal("locale should be omitted before it is ever set")
	}

	// Regional tags fold to the base language.
	rec := doJSON(t, "PATCH", "/api/v1/auth/account", token, map[string]any{"locale": "es-MX"})
	if rec.Code != http.StatusOK || decode(t, rec)["locale"] != "es" {
		t.Fatalf("patch locale = %d: %s", rec.Code, rec.Body.String())
	}
	if got := decode(t, doJSON(t, "GET", "/api/v1/auth/me", token, nil))["locale"]; got != "es" {
		t.Fatalf("/auth/me locale = %v, want es", got)
	}

	// A locale-only patch must not disturb the display name, and vice versa.
	rec = doJSON(t, "PATCH", "/api/v1/auth/account", token, map[string]any{"display_name": "Brian D"})
	if body := decode(t, rec); body["display_name"] != "Brian D" || body["locale"] != "es" {
		t.Fatalf("display-name patch clobbered locale: %s", rec.Body.String())
	}

	if rec := doJSON(t, "PATCH", "/api/v1/auth/account", token, map[string]any{
		"locale": "klingon",
	}); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("unsupported locale = %d, want 422", rec.Code)
	}
	if rec := doJSON(t, "PATCH", "/api/v1/auth/account", token, map[string]any{}); rec.Code != http.StatusBadRequest {
		t.Fatalf("empty patch = %d, want 400", rec.Code)
	}
}

func TestChangePasswordRevokesOtherSessions(t *testing.T) {
	resetDB(t)
	user, tokenA := createTestUser(t, "me@example.com")
	// A second device.
	tokenB, err := issueSession(t.Context(), store.New(dbPool), user.ID)
	if err != nil {
		t.Fatal(err)
	}

	// Wrong current password rejected.
	if rec := doJSON(t, "POST", "/api/v1/auth/change-password", tokenA, map[string]any{
		"current_password": "wrong", "new_password": "brand-new-pass",
	}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong current = %d, want 401", rec.Code)
	}

	rec := doJSON(t, "POST", "/api/v1/auth/change-password", tokenA, map[string]any{
		"current_password": "password123", "new_password": "brand-new-pass",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("change = %d: %s", rec.Code, rec.Body.String())
	}
	fresh, _ := decode(t, rec)["token"].(string)
	if fresh == "" {
		t.Fatal("no fresh token returned")
	}

	// Old sessions (both devices) are dead; the fresh one works; the new
	// password logs in.
	if r := doJSON(t, "GET", "/api/v1/auth/me", tokenA, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("old session A alive = %d", r.Code)
	}
	if r := doJSON(t, "GET", "/api/v1/auth/me", tokenB, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("old session B alive = %d", r.Code)
	}
	if r := doJSON(t, "GET", "/api/v1/auth/me", fresh, nil); r.Code != http.StatusOK {
		t.Fatalf("fresh session dead = %d", r.Code)
	}
	if r := doJSON(t, "POST", "/api/v1/auth/login", "", map[string]any{
		"email": "me@example.com", "password": "brand-new-pass",
	}); r.Code != http.StatusOK {
		t.Fatalf("login with new password = %d", r.Code)
	}
}

func TestLogoutAllDevices(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "me@example.com")
	otherToken, err := issueSession(t.Context(), store.New(dbPool), user.ID)
	if err != nil {
		t.Fatal(err)
	}

	if rec := doJSON(t, "POST", "/api/v1/auth/logout-all", token, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("logout-all = %d", rec.Code)
	}
	if r := doJSON(t, "GET", "/api/v1/auth/me", otherToken, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("other device still signed in = %d", r.Code)
	}
}

func TestDeleteAccountCascades(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "gone@example.com")
	trip := createTestTrip(t, user.ID, 2)

	// Wrong password refuses deletion.
	if rec := doJSON(t, "DELETE", "/api/v1/auth/account", token, map[string]any{
		"password": "wrong",
	}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong password delete = %d, want 401", rec.Code)
	}

	rec := doJSON(t, "DELETE", "/api/v1/auth/account", token, map[string]any{
		"password": "password123",
	})
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete = %d: %s", rec.Code, rec.Body.String())
	}

	// Session dead, login dead, trips gone (FK cascade).
	if r := doJSON(t, "GET", "/api/v1/auth/me", token, nil); r.Code != http.StatusUnauthorized {
		t.Fatalf("session survived deletion = %d", r.Code)
	}
	if r := doJSON(t, "POST", "/api/v1/auth/login", "", map[string]any{
		"email": "gone@example.com", "password": "password123",
	}); r.Code != http.StatusUnauthorized {
		t.Fatalf("login after deletion = %d", r.Code)
	}
	var count int
	if err := dbPool.QueryRow(t.Context(),
		`SELECT count(*) FROM trips WHERE id = $1`, trip.ID).Scan(&count); err != nil || count != 0 {
		t.Fatalf("trip survived deletion (count=%d, err=%v)", count, err)
	}
}
