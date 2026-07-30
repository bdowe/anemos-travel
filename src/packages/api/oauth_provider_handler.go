package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// oauth_provider_handler.go: the OAuth 2.1 provider endpoints behind the MCP
// connector (specs/mcp-connector). ChatGPT/claude.ai discover us via the
// well-known documents, register as public clients (DCR), send the user's
// browser through the Flutter consent screen, and exchange the code for
// hashed, rotating tokens. Everything here 404s until MCP_ENABLED=true so
// deploying the code exposes nothing.
//
// Error-shape note: the register and token endpoints speak the RFC-mandated
// {"error": "..."} JSON (RFC 7591 §3.2.2 / RFC 6749 §5.2), NOT the app's
// writeJSONError envelope — MCP clients parse these fields.

// mcpEnabled is the feature gate, read per request like the SSO *Configured()
// helpers so tests and ops can flip it without a boot-order dependency.
func mcpEnabled() bool {
	return os.Getenv("MCP_ENABLED") == "true"
}

// oauthGuard applies the gate + DB check every OAuth endpoint starts with.
func oauthGuard(w http.ResponseWriter) bool {
	if !mcpEnabled() {
		http.Error(w, "not found", http.StatusNotFound)
		return false
	}
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return false
	}
	return true
}

func mcpResourceURL() string { return publicBaseURL() + "/mcp" }

// --- discovery documents -----------------------------------------------------

// GET /.well-known/oauth-protected-resource[/mcp] (RFC 9728). Both path forms
// are served because client probing order varies by release.
func oauthProtectedResourceHandler(w http.ResponseWriter, r *http.Request) {
	if !mcpEnabled() {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"resource":                 mcpResourceURL(),
		"authorization_servers":    []string{publicBaseURL()},
		"scopes_supported":         []string{oauthScopeTripsWrite, oauthScopeRecsRead},
		"bearer_methods_supported": []string{"header"},
	})
}

// GET /.well-known/oauth-authorization-server (RFC 8414), plus an
// openid-configuration alias for clients that probe that first.
func oauthServerMetadataHandler(w http.ResponseWriter, r *http.Request) {
	if !mcpEnabled() {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	base := publicBaseURL()
	writeJSON(w, http.StatusOK, map[string]any{
		"issuer":                                base,
		"authorization_endpoint":                base + "/api/v1/oauth/authorize",
		"token_endpoint":                        base + "/api/v1/oauth/token",
		"registration_endpoint":                 base + "/api/v1/oauth/register",
		"response_types_supported":              []string{"code"},
		"grant_types_supported":                 []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":      []string{"S256"},
		"token_endpoint_auth_methods_supported": []string{"none"},
		"scopes_supported":                      []string{oauthScopeTripsWrite, oauthScopeRecsRead},
	})
}

// --- dynamic client registration (RFC 7591) ----------------------------------

type oauthRegisterRequest struct {
	ClientName              string   `json:"client_name"`
	RedirectURIs            []string `json:"redirect_uris"`
	TokenEndpointAuthMethod string   `json:"token_endpoint_auth_method"`
}

func oauthRegistrationError(w http.ResponseWriter, code, desc string) {
	writeJSON(w, http.StatusBadRequest, map[string]string{
		"error": code, "error_description": desc,
	})
}

// validOAuthRedirectURI: https anywhere, or http on loopback hosts (MCP
// Inspector and other local dev tools); never a fragment.
func validOAuthRedirectURI(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Fragment != "" || u.Host == "" {
		return false
	}
	switch u.Scheme {
	case "https":
		return true
	case "http":
		h := u.Hostname()
		return h == "localhost" || h == "127.0.0.1" || h == "::1"
	}
	return false
}

// POST /api/v1/oauth/register — open registration, public clients only.
func oauthRegisterHandler(w http.ResponseWriter, r *http.Request) {
	if !oauthGuard(w) {
		return
	}
	var req oauthRegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		oauthRegistrationError(w, "invalid_client_metadata", "invalid JSON")
		return
	}
	name := strings.TrimSpace(req.ClientName)
	if name == "" || len(name) > maxNameLen {
		oauthRegistrationError(w, "invalid_client_metadata", "client_name is required")
		return
	}
	if len(req.RedirectURIs) == 0 || len(req.RedirectURIs) > 5 {
		oauthRegistrationError(w, "invalid_redirect_uri", "between 1 and 5 redirect_uris required")
		return
	}
	for _, u := range req.RedirectURIs {
		if len(u) > maxURLLen || !validOAuthRedirectURI(u) {
			oauthRegistrationError(w, "invalid_redirect_uri", "redirect_uris must be https (or http://localhost) with no fragment")
			return
		}
	}
	if m := strings.TrimSpace(req.TokenEndpointAuthMethod); m != "" && m != "none" {
		oauthRegistrationError(w, "invalid_client_metadata", "only public clients (token_endpoint_auth_method 'none') are supported")
		return
	}

	client, err := store.New(dbPool).CreateOAuthClient(r.Context(), store.CreateOAuthClientParams{
		ClientName: name, RedirectUris: req.RedirectURIs,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not register client")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"client_id":                  client.ID.String(),
		"client_name":                client.ClientName,
		"redirect_uris":              client.RedirectUris,
		"token_endpoint_auth_method": "none",
		"grant_types":                []string{"authorization_code", "refresh_token"},
		"response_types":             []string{"code"},
	})
}

// --- authorize ----------------------------------------------------------------

// oauthErrorPage: for failures where redirecting would be an open-redirect
// vector (unknown client, unregistered redirect_uri) — render, never redirect.
func oauthErrorPage(w http.ResponseWriter, locale, body string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusBadRequest)
	fmt.Fprintf(w, "<html lang=%q><body><h2>%s</h2><p>%s</p></body></html>",
		locale, "Golden Tempo Travel", body)
}

// oauthRedirectError sends the RFC 6749 §4.1.2.1 error redirect for failures
// discovered AFTER the redirect_uri itself validated.
func oauthRedirectError(w http.ResponseWriter, r *http.Request, redirectURI, code, state string) {
	u, err := url.Parse(redirectURI)
	if err != nil {
		oauthErrorPage(w, requestLocale(r.Context()), "invalid redirect")
		return
	}
	q := u.Query()
	q.Set("error", code)
	if state != "" {
		q.Set("state", state)
	}
	u.RawQuery = q.Encode()
	http.Redirect(w, r, u.String(), http.StatusFound)
}

// GET /api/v1/oauth/authorize — validates the request, parks it, and sends
// the browser to the Flutter consent screen at /connect/<request-token>.
func oauthAuthorizeHandler(w http.ResponseWriter, r *http.Request) {
	if !oauthGuard(w) {
		return
	}
	locale := requestLocale(r.Context())
	qp := r.URL.Query()
	q := store.New(dbPool)

	// Opportunistic janitor, same posture as DeleteExpiredSessions.
	// context.Background(): the request context dies with this handler.
	safeGo("oauthJanitor", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		jq := store.New(dbPool)
		_ = jq.DeleteExpiredOAuthAuthCodes(ctx)
		_ = jq.DeleteExpiredOAuthTokens(ctx)
	})

	clientID, err := uuid.Parse(qp.Get("client_id"))
	if err != nil {
		oauthErrorPage(w, locale, "Unknown application (bad client_id). Start over from your AI assistant.")
		return
	}
	client, err := q.GetOAuthClient(r.Context(), clientID)
	if err != nil {
		oauthErrorPage(w, locale, "Unknown application. Start over from your AI assistant.")
		return
	}
	redirectURI := qp.Get("redirect_uri")
	registered := false
	for _, u := range client.RedirectUris {
		if u == redirectURI {
			registered = true
			break
		}
	}
	if !registered {
		// The one place we must never redirect: an attacker-chosen URI.
		oauthErrorPage(w, locale, "This application supplied an unregistered redirect address.")
		return
	}

	state := qp.Get("state")
	if qp.Get("response_type") != "code" {
		oauthRedirectError(w, r, redirectURI, "unsupported_response_type", state)
		return
	}
	if qp.Get("code_challenge") == "" || qp.Get("code_challenge_method") != "S256" {
		oauthRedirectError(w, r, redirectURI, "invalid_request", state)
		return
	}
	scope, ok := normalizeOAuthScope(qp.Get("scope"))
	if !ok {
		oauthRedirectError(w, r, redirectURI, "invalid_scope", state)
		return
	}
	// RFC 8707 resource indicator: when present it must name our MCP server.
	if res := qp.Get("resource"); res != "" && res != mcpResourceURL() {
		oauthRedirectError(w, r, redirectURI, "invalid_target", state)
		return
	}

	rawToken, tokenHash, err := newOAuthSecret(oauthRequestTokenPrefix)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not start authorization")
		return
	}
	if _, err := q.CreateOAuthAuthRequest(r.Context(), store.CreateOAuthAuthRequestParams{
		ClientID:         client.ID,
		RequestTokenHash: tokenHash,
		RedirectUri:      redirectURI,
		Scope:            scope,
		State:            state,
		CodeChallenge:    qp.Get("code_challenge"),
		ExpiresAt:        time.Now().Add(oauthRequestTokenTTL),
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not start authorization")
		return
	}
	_ = q.TouchOAuthClient(r.Context(), client.ID)

	http.Redirect(w, r, publicAppURL("connect/", rawToken), http.StatusSeeOther)
}

// --- consent screen backend ----------------------------------------------------

type oauthContextRequest struct {
	RequestToken string `json:"request_token"`
}

// POST /api/v1/oauth/authorize/context — unauthenticated on purpose: the
// 256-bit single-use request token IS the credential, and the consent screen
// must render before sign-in completes.
func oauthAuthorizeContextHandler(w http.ResponseWriter, r *http.Request) {
	if !oauthGuard(w) {
		return
	}
	var req oauthContextRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RequestToken == "" {
		writeJSONError(w, http.StatusBadRequest, "request_token is required")
		return
	}
	row, err := store.New(dbPool).GetOAuthAuthRequestByRequestHash(r.Context(), hashBearerToken(req.RequestToken))
	if err != nil || row.ApprovedAt.Valid {
		writeJSONError(w, http.StatusGone, "authorization request expired — start over from your AI assistant")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"client_name": row.ClientName,
		"scopes":      strings.Fields(row.Scope),
		"expires_at":  row.ExpiresAt,
	})
}

type oauthDecisionRequest struct {
	RequestToken string `json:"request_token"`
	Approve      bool   `json:"approve"`
}

// POST /api/v1/oauth/authorize/decision (authMiddleware) — binds the
// signed-in user, upserts the consent grant, mints the code.
func oauthAuthorizeDecisionHandler(w http.ResponseWriter, r *http.Request) {
	if !oauthGuard(w) {
		return
	}
	user, ok := userFromContext(r.Context())
	if !ok {
		writeJSONError(w, http.StatusUnauthorized, "authentication required")
		return
	}
	var req oauthDecisionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RequestToken == "" {
		writeJSONError(w, http.StatusBadRequest, "request_token is required")
		return
	}
	q := store.New(dbPool)
	requestHash := hashBearerToken(req.RequestToken)
	row, err := q.GetOAuthAuthRequestByRequestHash(r.Context(), requestHash)
	if err != nil || row.ApprovedAt.Valid {
		writeJSONError(w, http.StatusGone, "authorization request expired — start over from your AI assistant")
		return
	}

	redirect, err := url.Parse(row.RedirectUri)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "invalid stored redirect")
		return
	}
	rq := redirect.Query()
	if row.State != "" {
		rq.Set("state", row.State)
	}

	if !req.Approve {
		_ = q.DeleteOAuthAuthRequest(r.Context(), requestHash)
		rq.Set("error", "access_denied")
		redirect.RawQuery = rq.Encode()
		writeJSON(w, http.StatusOK, map[string]string{"redirect_url": redirect.String()})
		return
	}

	if _, err := q.UpsertOAuthGrant(r.Context(), store.UpsertOAuthGrantParams{
		UserID: user.ID, ClientID: row.ClientID, Scope: row.Scope,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not record consent")
		return
	}
	rawCode, codeHash, err := newOAuthSecret(oauthCodePrefix)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not mint code")
		return
	}
	// Conditional UPDATE (approved_at IS NULL) makes the consent handle
	// single-use even under concurrent decisions.
	if _, err := q.ApproveOAuthAuthRequest(r.Context(), store.ApproveOAuthAuthRequestParams{
		RequestTokenHash: requestHash,
		UserID:           pgtype.UUID{Bytes: user.ID, Valid: true},
		CodeHash:         &codeHash,
		ExpiresAt:        time.Now().Add(oauthCodeTTL),
	}); err != nil {
		writeJSONError(w, http.StatusGone, "authorization request expired — start over from your AI assistant")
		return
	}

	rq.Set("code", rawCode)
	redirect.RawQuery = rq.Encode()
	writeJSON(w, http.StatusOK, map[string]string{"redirect_url": redirect.String()})
}

// --- token endpoint -------------------------------------------------------------

// oauthTokenError speaks RFC 6749 §5.2.
func oauthTokenError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

// POST /api/v1/oauth/token — form-encoded per spec.
func oauthTokenHandler(w http.ResponseWriter, r *http.Request) {
	if !oauthGuard(w) {
		return
	}
	if err := r.ParseForm(); err != nil {
		oauthTokenError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	switch r.PostForm.Get("grant_type") {
	case "authorization_code":
		oauthTokenAuthorizationCode(w, r)
	case "refresh_token":
		oauthTokenRefresh(w, r)
	default:
		oauthTokenError(w, http.StatusBadRequest, "unsupported_grant_type")
	}
}

func oauthTokenAuthorizationCode(w http.ResponseWriter, r *http.Request) {
	q := store.New(dbPool)
	form := r.PostForm

	clientID, err := uuid.Parse(form.Get("client_id"))
	if err != nil {
		oauthTokenError(w, http.StatusUnauthorized, "invalid_client")
		return
	}
	codeHash := hashBearerToken(form.Get("code"))
	row, err := q.GetOAuthAuthCodeByCodeHash(r.Context(), &codeHash)
	if err != nil {
		oauthTokenError(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	if row.CodeUsedAt.Valid {
		// Code reuse is the classic stolen-code signal: kill everything the
		// first redemption minted (RFC 6749 §4.1.2), then refuse.
		_ = q.RevokeOAuthTokensByAuthCode(r.Context(), pgtype.UUID{Bytes: row.ID, Valid: true})
		oauthTokenError(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	if row.ClientID != clientID ||
		row.RedirectUri != form.Get("redirect_uri") ||
		!row.ApprovedAt.Valid || !row.UserID.Valid ||
		time.Now().After(row.ExpiresAt) {
		oauthTokenError(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	// PKCE S256, constant-time.
	computed := pkceChallenge(form.Get("code_verifier"))
	if subtle.ConstantTimeCompare([]byte(computed), []byte(row.CodeChallenge)) != 1 {
		oauthTokenError(w, http.StatusBadRequest, "invalid_grant")
		return
	}

	userID := uuid.UUID(row.UserID.Bytes)
	grant, err := q.GetOAuthGrantByUserAndClient(r.Context(), store.GetOAuthGrantByUserAndClientParams{
		UserID: userID, ClientID: row.ClientID,
	})
	if err != nil || grant.RevokedAt.Valid {
		oauthTokenError(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	if err := q.MarkOAuthCodeUsed(r.Context(), row.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not redeem code")
		return
	}
	issueOAuthTokenPair(w, r, grant.ID, grant.Scope, pgtype.UUID{Bytes: row.ID, Valid: true})
}

func oauthTokenRefresh(w http.ResponseWriter, r *http.Request) {
	q := store.New(dbPool)
	form := r.PostForm

	row, err := q.GetOAuthTokenByRefreshHash(r.Context(), hashBearerToken(form.Get("refresh_token")))
	if err != nil || row.GrantRevokedAt.Valid {
		oauthTokenError(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	if cid := form.Get("client_id"); cid != "" && cid != row.ClientID.String() {
		oauthTokenError(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	// Rotation: the presented refresh token dies with this exchange.
	if err := q.RevokeOAuthToken(r.Context(), row.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not rotate token")
		return
	}
	issueOAuthTokenPair(w, r, row.GrantID, row.Scope, row.AuthCodeID)
}

func issueOAuthTokenPair(w http.ResponseWriter, r *http.Request, grantID uuid.UUID, scope string, authCodeID pgtype.UUID) {
	rawAccess, accessHash, err1 := newOAuthSecret(oauthAccessTokenPrefix)
	rawRefresh, refreshHash, err2 := newOAuthSecret(oauthRefreshTokenPrefix)
	if err1 != nil || err2 != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not mint tokens")
		return
	}
	if _, err := store.New(dbPool).CreateOAuthTokenPair(r.Context(), store.CreateOAuthTokenPairParams{
		GrantID:          grantID,
		AuthCodeID:       authCodeID,
		AccessTokenHash:  accessHash,
		RefreshTokenHash: refreshHash,
		AccessExpiresAt:  time.Now().Add(oauthAccessTokenTTL),
		RefreshExpiresAt: time.Now().Add(oauthRefreshTokenTTL),
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not mint tokens")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token":  rawAccess,
		"token_type":    "Bearer",
		"expires_in":    int(oauthAccessTokenTTL.Seconds()),
		"refresh_token": rawRefresh,
		"scope":         scope,
	})
}
