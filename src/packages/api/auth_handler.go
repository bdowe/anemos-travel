package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

// --- request / response types ---

type RegisterRequest struct {
	Email       string  `json:"email"`
	Password    string  `json:"password"`
	DisplayName *string `json:"display_name"`
}

type LoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type UserResponse struct {
	ID              string    `json:"id"`
	Email           string    `json:"email"`
	DisplayName     string    `json:"display_name"`
	IsAdmin         bool      `json:"is_admin"`
	NeedsOnboarding bool      `json:"needs_onboarding"`
	CreatedAt       time.Time `json:"created_at"`
	// Email preferences are expressed to the client as opt-INs (receiving = on)
	// so the account-settings switches read naturally; they invert the stored
	// opt-out columns.
	RemindersEnabled bool `json:"reminders_enabled"`
	NudgesEnabled    bool `json:"nudges_enabled"`
	// Preferred language ('en' | 'es'), omitted when the account has never
	// resolved one. The client owns resolution and syncs it here; the server
	// reads it only where there is no request to negotiate from — background
	// email and token-gated exports (specs/i18n-spanish).
	Locale *string `json:"locale,omitempty"`
}

type AuthResponse struct {
	User  UserResponse `json:"user"`
	Token string       `json:"token"`
}

func toUserResponse(u store.User) UserResponse {
	name := ""
	if u.DisplayName != nil {
		name = *u.DisplayName
	}
	return UserResponse{
		ID:              u.ID.String(),
		Email:           u.Email,
		DisplayName:     name,
		IsAdmin:         u.IsAdmin,
		NeedsOnboarding: !u.OnboardedAt.Valid,
		CreatedAt:       u.CreatedAt,
		// Opt-out false => still receiving => enabled true.
		RemindersEnabled: !u.RemindersOptOut,
		NudgesEnabled:    !u.NudgesOptOut,
		Locale:           u.Locale,
	}
}

// --- small response helpers ---

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeJSONError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, Response{Message: msg, Status: "error"})
}

// --- auth context + middleware ---

type contextKey string

const userContextKey contextKey = "user"

func bearerToken(r *http.Request) string {
	const prefix = "Bearer "
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, prefix) {
		return strings.TrimSpace(h[len(prefix):])
	}
	return ""
}

func userFromContext(ctx context.Context) (store.User, bool) {
	u, ok := ctx.Value(userContextKey).(store.User)
	return u, ok
}

// userIDFromRequest resolves the bearer token to a user ID without failing the
// request when the token is absent/invalid. Used by endpoints that are open to
// anonymous callers but persist data only when signed in (e.g. /plan).
//
// The third return value is a DB-availability error: when a token WAS presented
// but the session lookup failed because the database is unreachable, it returns
// (zero, false, errDBUnavailable) so the caller can answer "temporarily
// unavailable" instead of silently downgrading an authenticated user to
// anonymous (which would drop their personalization and persistence on a blip).
// Genuinely-absent/expired sessions still return (zero, false, nil) — anonymous.
func userIDFromRequest(r *http.Request) (uuid.UUID, bool, error) {
	if dbPool == nil {
		return uuid.UUID{}, false, nil
	}
	token := bearerToken(r)
	if token == "" {
		return uuid.UUID{}, false, nil
	}
	row, err := store.New(dbPool).GetSessionWithUser(r.Context(), hashBearerToken(token))
	if err != nil {
		if dbErrorStatus(err) == http.StatusServiceUnavailable {
			ctxLog(r.Context()).Error("auth: session lookup failed (db)", "error", err)
			return uuid.UUID{}, false, errDBUnavailable
		}
		return uuid.UUID{}, false, nil // absent/expired session -> anonymous
	}
	if row.Session.ExpiresAt.Before(time.Now()) {
		return uuid.UUID{}, false, nil
	}
	return row.User.ID, true, nil
}

// errDBUnavailable signals that a request could not be resolved because the
// database was temporarily unreachable — the caller should return 503, not
// treat the request as anonymous or unauthenticated.
var errDBUnavailable = errors.New("database temporarily unavailable")

// authMiddleware resolves the bearer token to a user and rejects unauthenticated
// requests with 401. Wrap only the routes that require authentication.
func authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if dbPool == nil {
			writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
			return
		}
		token := bearerToken(r)
		if token == "" {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		q := store.New(dbPool)
		row, err := q.GetSessionWithUser(r.Context(), hashBearerToken(token))
		if err != nil {
			// A DB-connection failure (Postgres restarting, pool closed, conn
			// refused) must NOT masquerade as an invalid session — that logs
			// every user out on a transient blip. Answer 503 (retryable) and
			// keep 401 strictly for a genuinely absent/expired session.
			if dbErrorStatus(err) == http.StatusServiceUnavailable {
				ctxLog(r.Context()).Error("auth: session lookup failed (db)", "error", err)
				writeJSONError(w, http.StatusServiceUnavailable, "service temporarily unavailable")
				return
			}
			if errors.Is(err, pgx.ErrNoRows) {
				writeJSONError(w, http.StatusUnauthorized, "invalid or expired session")
				return
			}
			// Unexpected non-connection error: log and 500 rather than silently
			// rejecting a possibly-valid session as unauthorized.
			ctxLog(r.Context()).Error("auth: unexpected session lookup error", "error", err)
			writeJSONError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if row.Session.ExpiresAt.Before(time.Now()) {
			writeJSONError(w, http.StatusUnauthorized, "invalid or expired session")
			return
		}
		_ = q.DeleteExpiredSessions(r.Context()) // opportunistic cleanup
		ctx := context.WithValue(r.Context(), userContextKey, row.User)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// adminMiddleware runs after authMiddleware's token→user resolution and rejects
// non-admin users with 403. Wrap admin-only routes as
// authMiddleware(adminMiddleware(handler)).
func adminMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, ok := userFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		if !user.IsAdmin {
			writeJSONError(w, http.StatusForbidden, "admin access required")
			return
		}
		next.ServeHTTP(w, r.WithContext(r.Context()))
	})
}

// --- handlers ---

func registerHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if !validateEmail(req.Email) {
		writeJSONError(w, http.StatusUnprocessableEntity, "a valid email address is required")
		return
	}
	if len(req.Password) < 8 {
		writeJSONError(w, http.StatusUnprocessableEntity, "password must be at least 8 characters")
		return
	}
	// Cap the optional display name, mirroring the account-update path's 60-rune
	// limit (account_handler.go). Empty/absent falls back to a default below.
	if req.DisplayName != nil {
		if _, err := boundedString("display_name", *req.DisplayName, maxDisplayNameLen); err != nil {
			writeJSONError(w, http.StatusUnprocessableEntity, err.Error())
			return
		}
	}

	// Per-IP daily account-creation ceiling (abuse_caps.go): stops one network
	// from minting accounts en masse. Counts only successful creations (bumped
	// below), so failed/duplicate attempts don't burn the budget. Generic 429.
	ip := clientIP(r)
	if registrationCounter.count(ip, time.Now()) >= registrationsPerIPPerDay() {
		w.Header().Set("Retry-After", "3600")
		writeJSONError(w, http.StatusTooManyRequests, "too many accounts created from this network today; please try again later")
		return
	}

	q := store.New(dbPool)
	if _, err := q.GetUserByEmail(r.Context(), req.Email); err == nil {
		writeJSONError(w, http.StatusConflict, "an account with this email already exists")
		return
	} else if !errors.Is(err, pgx.ErrNoRows) {
		writeJSONError(w, http.StatusInternalServerError, "could not check email")
		return
	}

	hash, err := hashPassword(req.Password)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not secure password")
		return
	}

	displayName := req.DisplayName
	if displayName == nil || strings.TrimSpace(*displayName) == "" {
		d := defaultDisplayName(req.Email)
		displayName = &d
	}

	signupLocale := requestLocale(r.Context())
	user, err := q.CreateUser(r.Context(), store.CreateUserParams{
		Email:        req.Email,
		PasswordHash: &hash,
		DisplayName:  displayName,
		Locale:       &signupLocale,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create account")
		return
	}
	// Count the successful creation toward this IP's daily ceiling.
	registrationCounter.incr(ip, time.Now())

	token, err := issueSession(r.Context(), q, user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not start session")
		return
	}
	// Fire-and-forget, like the profile distiller: registration never blocks
	// or fails on email delivery or analytics.
	safeGo("sendVerificationEmail", func() { sendVerificationEmailIn(user, signupLocale) })
	safeGo("recordEvent", func() { recordEvent(user.ID, "user_registered", nil, nil) })
	writeJSON(w, http.StatusCreated, AuthResponse{User: toUserResponse(user), Token: token})
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if req.Email == "" || req.Password == "" {
		writeJSONError(w, http.StatusUnprocessableEntity, "email and password are required")
		return
	}

	// Per-account login lockout (abuse_caps.go): the strict 5/min/IP limiter
	// alone doesn't stop credential stuffing spread across many IPs, so track
	// consecutive failures keyed by email and temporarily lock after too many.
	// The lock fires identically whether or not the email exists — an attacker
	// probing one address can never tell existence from the 429, preserving the
	// no-user-enumeration guarantee below.
	now := time.Now()
	if loginLockouts.locked(req.Email, now) {
		w.Header().Set("Retry-After", strconv.Itoa(int(loginLockWindow().Seconds())))
		writeJSONError(w, http.StatusTooManyRequests, "too many failed login attempts; please wait a few minutes and try again")
		return
	}

	q := store.New(dbPool)
	user, err := q.GetUserByEmail(r.Context(), req.Email)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !checkUserPassword(user, req.Password)) {
		// Generic message — never reveal whether the email or the password was
		// wrong. Both misses count toward the lockout so the counter accrues the
		// same way for real and non-existent accounts.
		loginLockouts.recordFailure(req.Email, now)
		writeJSONError(w, http.StatusUnauthorized, "invalid email or password")
		return
	}
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not look up account")
		return
	}

	// Successful auth clears the failure streak.
	loginLockouts.reset(req.Email)

	token, err := issueSession(r.Context(), q, user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not start session")
		return
	}
	writeJSON(w, http.StatusOK, AuthResponse{User: toUserResponse(user), Token: token})
}

func logoutHandler(w http.ResponseWriter, r *http.Request) {
	if token := bearerToken(r); token != "" && dbPool != nil {
		_ = store.New(dbPool).DeleteSession(r.Context(), hashBearerToken(token))
	}
	w.WriteHeader(http.StatusNoContent)
}

func meHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := userFromContext(r.Context())
	if !ok {
		writeJSONError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	writeJSON(w, http.StatusOK, toUserResponse(user))
}

// completeOnboardingHandler marks the signup quiz as done (or skipped).
// Idempotent: repeat calls keep the original onboarded_at.
func completeOnboardingHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := userFromContext(r.Context())
	if !ok {
		writeJSONError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	updated, err := store.New(dbPool).MarkUserOnboarded(r.Context(), user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not complete onboarding")
		return
	}
	safeGo("recordEvent", func() { recordEvent(user.ID, "onboarding_completed", nil, nil) })
	writeJSON(w, http.StatusOK, toUserResponse(updated))
}
