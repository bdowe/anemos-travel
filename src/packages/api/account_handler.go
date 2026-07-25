package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"

	"travel-route-planner/store"
)

// Account self-service: display name, password change, session revocation,
// deletion. All behind authMiddleware; the destructive/credential routes sit
// on the strict rate tier and re-verify the password (a stolen session must
// not be enough to take over or destroy the account).

func patchAccountHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	var req struct {
		DisplayName *string `json:"display_name"`
		Locale      *string `json:"locale"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.DisplayName == nil && req.Locale == nil {
		writeJSONError(w, http.StatusBadRequest, "nothing to update")
		return
	}
	params := store.UpdateUserProfileParams{ID: user.ID}
	if req.DisplayName != nil {
		name := strings.TrimSpace(*req.DisplayName)
		if name == "" || utf8.RuneCountInString(name) > 60 {
			writeJSONError(w, http.StatusUnprocessableEntity, "display_name must be 1-60 characters")
			return
		}
		params.DisplayName = &name
	}
	// The client syncs its already-resolved effective locale here (specs/
	// i18n-spanish), so background email has a language to write in. Regional
	// tags fold to their base language; anything unsupported is a client bug.
	if req.Locale != nil {
		locale, ok := normalizeLocale(*req.Locale)
		if !ok {
			writeJSONError(w, http.StatusUnprocessableEntity, "unsupported locale")
			return
		}
		params.Locale = &locale
	}
	updated, err := store.New(dbPool).UpdateUserProfile(r.Context(), params)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not update account")
		return
	}
	writeJSON(w, http.StatusOK, toUserResponse(updated))
}

// patchEmailPreferencesHandler updates the signed-in user's email opt-outs. The
// client speaks opt-IN ("enabled"): switch ON = receiving = opt_out false. Both
// fields are optional pointers so the UI can toggle one stream at a time; a body
// touching neither is a no-op that still returns the current user.
func patchEmailPreferencesHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	var req struct {
		RemindersEnabled *bool `json:"reminders_enabled"`
		NudgesEnabled    *bool `json:"nudges_enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	params := store.SetUserEmailOptOutParams{ID: user.ID}
	if req.RemindersEnabled != nil {
		optOut := !*req.RemindersEnabled
		params.RemindersOptOut = &optOut
	}
	if req.NudgesEnabled != nil {
		optOut := !*req.NudgesEnabled
		params.NudgesOptOut = &optOut
	}
	updated, err := store.New(dbPool).SetUserEmailOptOut(r.Context(), params)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not update email preferences")
		return
	}
	writeJSON(w, http.StatusOK, toUserResponse(updated))
}

func changePasswordHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	var req struct {
		CurrentPassword string `json:"current_password"`
		NewPassword     string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if !hasPassword(user) {
		writeJSONError(w, http.StatusUnprocessableEntity, "This account signs in with Google. Use \"Forgot password\" to set a password first.")
		return
	}
	if !checkUserPassword(user, req.CurrentPassword) {
		writeJSONError(w, http.StatusUnauthorized, "current password is incorrect")
		return
	}
	if len(req.NewPassword) < 8 {
		writeJSONError(w, http.StatusUnprocessableEntity, "password must be at least 8 characters")
		return
	}
	hash, err := hashPassword(req.NewPassword)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not secure password")
		return
	}
	q := store.New(dbPool)
	if err := q.UpdateUserPassword(r.Context(), store.UpdateUserPasswordParams{ID: user.ID, PasswordHash: &hash}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not update password")
		return
	}
	// Same policy as password reset: every existing session dies with the old
	// password; a fresh one keeps this device signed in.
	if err := q.DeleteSessionsByUser(r.Context(), user.ID); err != nil {
		log.Printf("change password: could not revoke sessions for %s: %v", user.ID, err)
	}
	token, err := issueSession(r.Context(), q, user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "password changed — sign in again")
		return
	}
	writeJSON(w, http.StatusOK, AuthResponse{User: toUserResponse(user), Token: token})
}

func logoutAllHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	if err := store.New(dbPool).DeleteSessionsByUser(r.Context(), user.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not sign out other devices")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func deleteAccountHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	// SSO-only accounts have no password to re-verify; the session suffices.
	if hasPassword(user) && !checkUserPassword(user, req.Password) {
		writeJSONError(w, http.StatusUnauthorized, "password is incorrect")
		return
	}
	// Every user-owned table cascades off users(id); analytics_events keeps
	// its (PII-free) rows by design — the event log is append-only.
	n, err := store.New(dbPool).DeleteUser(r.Context(), user.ID)
	if err != nil || n == 0 {
		writeJSONError(w, http.StatusInternalServerError, "could not delete account")
		return
	}
	log.Printf("account deleted: %s", user.ID)
	w.WriteHeader(http.StatusNoContent)
}
