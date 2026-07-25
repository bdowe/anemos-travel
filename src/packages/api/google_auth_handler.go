package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

// Sign in with Google (specs/google-sso). The browser flow is:
//
//	GET /auth/google            302 to Google (state+PKCE in an HttpOnly cookie)
//	GET /auth/google/callback   code exchange, find-or-create user, then 303 to
//	                            the app at /sso/<one-time code> (or /sso/error)
//	POST /auth/google/exchange  the app swaps the one-time code for a session
//
// The one-time handoff code reuses the email_tokens machinery (purpose 'sso',
// 60s TTL, single-use, hashed at rest) because the code transits a URL.

const (
	googleStateCookie = "google_oauth_state"
	ssoHandoffTTL     = 60 * time.Second
)

func googleAvailabilityHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{
		"available": googleOAuthConfigured() && dbPool != nil,
	})
}

func googleStartHandler(w http.ResponseWriter, r *http.Request) {
	if !googleOAuthConfigured() || dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "Google sign-in is not configured")
		return
	}
	state, err := randomURLToken()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not start sign-in")
		return
	}
	verifier, err := randomURLToken()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not start sign-in")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     googleStateCookie,
		Value:    state + "." + verifier,
		Path:     "/api/v1/auth/google",
		MaxAge:   600,
		HttpOnly: true,
		Secure:   strings.HasPrefix(publicBaseURL(), "https://"),
		SameSite: http.SameSiteLaxMode,
	})
	params := url.Values{
		"client_id":             {googleOAuthClientID()},
		"redirect_uri":          {googleRedirectURI()},
		"response_type":         {"code"},
		"scope":                 {"openid email profile"},
		"state":                 {state},
		"code_challenge":        {pkceChallenge(verifier)},
		"code_challenge_method": {"S256"},
	}
	http.Redirect(w, r, googleAuthURL()+"?"+params.Encode(), http.StatusFound)
}

// googleCallbackHandler is a top-level browser navigation, so every failure
// redirects to the app's /sso/error route instead of rendering JSON.
func googleCallbackHandler(w http.ResponseWriter, r *http.Request) {
	redirectErr := func() {
		http.Redirect(w, r, publicAppURL("sso/", "error"), http.StatusSeeOther)
	}

	cookie, cookieErr := r.Cookie(googleStateCookie)
	// The cookie is single-use: clear it no matter how the callback ends.
	http.SetCookie(w, &http.Cookie{
		Name: googleStateCookie, Value: "", Path: "/api/v1/auth/google",
		MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteLaxMode,
		Secure: strings.HasPrefix(publicBaseURL(), "https://"),
	})

	if !googleOAuthConfigured() || dbPool == nil {
		redirectErr()
		return
	}
	if r.URL.Query().Get("error") != "" { // user declined the consent screen
		redirectErr()
		return
	}
	code := r.URL.Query().Get("code")
	state := r.URL.Query().Get("state")
	if code == "" || state == "" || cookieErr != nil {
		redirectErr()
		return
	}
	cookieState, verifier, ok := strings.Cut(cookie.Value, ".")
	if !ok || cookieState != state {
		redirectErr()
		return
	}

	claims, err := exchangeGoogleCode(r.Context(), code, verifier)
	if err != nil {
		ctxLog(r.Context()).Error("google oauth: code exchange failed", "error", err)
		redirectErr()
		return
	}

	user, err := findOrCreateGoogleUser(r, claims)
	if err != nil {
		ctxLog(r.Context()).Error("google oauth: find-or-create failed", "error", err)
		redirectErr()
		return
	}

	handoff, err := issueEmailToken(r.Context(), store.New(dbPool), user, "sso", ssoHandoffTTL)
	if err != nil {
		ctxLog(r.Context()).Error("google oauth: could not issue handoff code", "error", err)
		redirectErr()
		return
	}
	http.Redirect(w, r, publicAppURL("sso/", handoff), http.StatusSeeOther)
}

var errUnverifiedGoogleEmail = errors.New("google account email is not verified")

// findOrCreateGoogleUser applies the linking rules from specs/google-sso:
// known sub signs in; a verified matching email auto-links; otherwise a new
// account is created. An unverified Google email never links or signs in to
// an existing account (takeover guard).
func findOrCreateGoogleUser(r *http.Request, claims googleClaims) (store.User, error) {
	ctx := r.Context()
	q := store.New(dbPool)

	ident, err := q.GetAuthIdentity(ctx, store.GetAuthIdentityParams{
		Provider: "google", ProviderUserID: claims.Sub,
	})
	if err == nil {
		return q.GetUserByID(ctx, ident.UserID)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return store.User{}, err
	}

	email := strings.ToLower(strings.TrimSpace(claims.Email))
	if email == "" || !claims.EmailVerified {
		return store.User{}, errUnverifiedGoogleEmail
	}

	user, err := q.GetUserByEmail(ctx, email)
	if errors.Is(err, pgx.ErrNoRows) {
		displayName := strings.TrimSpace(claims.Name)
		if displayName == "" {
			displayName = defaultDisplayName(email)
		}
		signupLocale := requestLocale(ctx)
		user, err = q.CreateUser(ctx, store.CreateUserParams{
			Email: email, PasswordHash: nil, DisplayName: &displayName,
			Locale: &signupLocale,
		})
		if err != nil {
			return store.User{}, err
		}
		safeGo("recordEvent", func() { recordEvent(user.ID, "user_registered", nil, map[string]any{"method": "google"}) })
	} else if err != nil {
		return store.User{}, err
	}

	if _, err := q.CreateAuthIdentity(ctx, store.CreateAuthIdentityParams{
		UserID: user.ID, Provider: "google", ProviderUserID: claims.Sub, Email: &email,
	}); err != nil {
		return store.User{}, err
	}
	// Google vouched for the address — no verification email needed.
	if err := q.MarkUserEmailVerified(ctx, user.ID); err != nil {
		return store.User{}, err
	}
	return q.GetUserByID(ctx, user.ID)
}

// ssoExchangeHandler swaps the one-time handoff code for a real session.
// Response shape matches login so the app can adopt it directly. Provider-
// agnostic: the 'sso' tokens Google and Apple callbacks issue are identical.
func ssoExchangeHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Code) == "" {
		writeJSONError(w, http.StatusBadRequest, "code is required")
		return
	}
	q := store.New(dbPool)
	et, err := q.GetValidEmailToken(r.Context(), store.GetValidEmailTokenParams{
		TokenHash: hashEmailToken(strings.TrimSpace(req.Code)), Purpose: "sso",
	})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "invalid or expired sign-in code")
		return
	}
	if err := q.MarkEmailTokenUsed(r.Context(), et.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not complete sign-in")
		return
	}
	user, err := q.GetUserByID(r.Context(), et.UserID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not complete sign-in")
		return
	}
	token, err := issueSession(r.Context(), q, user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not start session")
		return
	}
	writeJSON(w, http.StatusOK, AuthResponse{User: toUserResponse(user), Token: token})
}
