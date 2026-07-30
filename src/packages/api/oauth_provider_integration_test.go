package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"travel-route-planner/store"
)

// OAuth provider integration tests (specs/mcp-connector): the full
// register → authorize → consent → token dance with a locally computed PKCE
// pair, plus the negative matrix (never-redirect guard, PKCE mismatch,
// single-use codes with reuse revocation, refresh rotation, feature gate).

func mcpTestEnv(t *testing.T) {
	t.Helper()
	t.Setenv("MCP_ENABLED", "true")
	t.Setenv("PUBLIC_BASE_URL", "http://gt.test")
}

// doForm drives the router with a form-encoded POST (the token endpoint's
// required content type; doJSON sends JSON).
func doForm(t *testing.T, path, token string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-Forwarded-For", nextTestIP())
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	testRouter.ServeHTTP(rec, req)
	return rec
}

// registerTestClient runs DCR and returns the client_id.
func registerTestClient(t *testing.T, redirectURI string) string {
	t.Helper()
	rec := doJSON(t, http.MethodPost, "/api/v1/oauth/register", "", map[string]any{
		"client_name": "Test AI", "redirect_uris": []string{redirectURI},
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("register: status = %d, body %s", rec.Code, rec.Body.String())
	}
	return decode(t, rec)["client_id"].(string)
}

// authorizeAndConsent walks authorize → context → decision and returns the
// authorization code from the decision's redirect URL.
func authorizeAndConsent(t *testing.T, clientID, redirectURI, challenge, sessionToken string) string {
	t.Helper()
	authURL := "/api/v1/oauth/authorize?" + url.Values{
		"client_id":             {clientID},
		"redirect_uri":          {redirectURI},
		"response_type":         {"code"},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"scope":                 {"trips:write recs:read"},
		"state":                 {"xyz"},
	}.Encode()
	rec := doJSON(t, http.MethodGet, authURL, "", nil)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("authorize: status = %d, body %s", rec.Code, rec.Body.String())
	}
	loc := rec.Header().Get("Location")
	if !strings.HasPrefix(loc, "http://gt.test/connect/") {
		t.Fatalf("authorize redirect = %q, want consent screen", loc)
	}
	requestToken := strings.TrimPrefix(loc, "http://gt.test/connect/")

	ctxRec := doJSON(t, http.MethodPost, "/api/v1/oauth/authorize/context", "", map[string]any{"request_token": requestToken})
	if ctxRec.Code != http.StatusOK {
		t.Fatalf("context: status = %d, body %s", ctxRec.Code, ctxRec.Body.String())
	}
	if name := decode(t, ctxRec)["client_name"]; name != "Test AI" {
		t.Fatalf("context client_name = %v", name)
	}

	decRec := doJSON(t, http.MethodPost, "/api/v1/oauth/authorize/decision", sessionToken,
		map[string]any{"request_token": requestToken, "approve": true})
	if decRec.Code != http.StatusOK {
		t.Fatalf("decision: status = %d, body %s", decRec.Code, decRec.Body.String())
	}
	redirectURL, err := url.Parse(decode(t, decRec)["redirect_url"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if redirectURL.Query().Get("state") != "xyz" {
		t.Fatalf("state not round-tripped: %s", redirectURL)
	}
	code := redirectURL.Query().Get("code")
	if !strings.HasPrefix(code, "gt_ac_") {
		t.Fatalf("code = %q, want gt_ac_ prefix", code)
	}
	return code
}

func redeemCode(t *testing.T, clientID, redirectURI, code, verifier string) *httptest.ResponseRecorder {
	t.Helper()
	return doForm(t, "/api/v1/oauth/token", "", url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"code_verifier": {verifier},
		"client_id":     {clientID},
		"redirect_uri":  {redirectURI},
	})
}

func TestOAuthFullDance(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	const redirectURI = "https://ai.example/callback"
	user, sessionToken := createTestUser(t, "oauth@example.com")

	clientID := registerTestClient(t, redirectURI)
	verifier, err := randomURLToken()
	if err != nil {
		t.Fatal(err)
	}
	code := authorizeAndConsent(t, clientID, redirectURI, pkceChallenge(verifier), sessionToken)

	rec := redeemCode(t, clientID, redirectURI, code, verifier)
	if rec.Code != http.StatusOK {
		t.Fatalf("token: status = %d, body %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	access := body["access_token"].(string)
	refresh := body["refresh_token"].(string)
	if !strings.HasPrefix(access, "gt_at_") || !strings.HasPrefix(refresh, "gt_rt_") {
		t.Fatalf("token prefixes wrong: %q %q", access, refresh)
	}
	if body["token_type"] != "Bearer" || body["scope"] != "trips:write recs:read" {
		t.Errorf("token metadata: %v", body)
	}

	// The access token must resolve to the consenting user.
	row, err := store.New(dbPool).GetOAuthTokenWithUserByAccessHash(context.Background(), hashBearerToken(access))
	if err != nil {
		t.Fatalf("access token lookup: %v", err)
	}
	if row.User.ID != user.ID {
		t.Errorf("token user = %s, want %s", row.User.ID, user.ID)
	}
	if row.Scope != "trips:write recs:read" {
		t.Errorf("grant scope = %q", row.Scope)
	}

	// Refresh rotates: new pair works, old refresh and old access die.
	refRec := doForm(t, "/api/v1/oauth/token", "", url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {refresh},
		"client_id":     {clientID},
	})
	if refRec.Code != http.StatusOK {
		t.Fatalf("refresh: status = %d, body %s", refRec.Code, refRec.Body.String())
	}
	newAccess := decode(t, refRec)["access_token"].(string)
	if _, err := store.New(dbPool).GetOAuthTokenWithUserByAccessHash(context.Background(), hashBearerToken(newAccess)); err != nil {
		t.Errorf("rotated access token must resolve: %v", err)
	}
	if _, err := store.New(dbPool).GetOAuthTokenWithUserByAccessHash(context.Background(), hashBearerToken(access)); err == nil {
		t.Error("pre-rotation access token must be revoked")
	}
	if again := doForm(t, "/api/v1/oauth/token", "", url.Values{
		"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID},
	}); again.Code != http.StatusBadRequest {
		t.Errorf("rotated-away refresh token: status = %d, want 400", again.Code)
	}
}

func TestOAuthCodeReuseRevokesTokens(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	const redirectURI = "https://ai.example/callback"
	_, sessionToken := createTestUser(t, "reuse@example.com")
	clientID := registerTestClient(t, redirectURI)
	verifier, _ := randomURLToken()
	code := authorizeAndConsent(t, clientID, redirectURI, pkceChallenge(verifier), sessionToken)

	first := redeemCode(t, clientID, redirectURI, code, verifier)
	if first.Code != http.StatusOK {
		t.Fatalf("first redemption: %d", first.Code)
	}
	access := decode(t, first)["access_token"].(string)

	second := redeemCode(t, clientID, redirectURI, code, verifier)
	if second.Code != http.StatusBadRequest || !strings.Contains(second.Body.String(), "invalid_grant") {
		t.Fatalf("code reuse: status = %d, body %s", second.Code, second.Body.String())
	}
	// Reuse is the stolen-code signal: the first redemption's tokens die.
	if _, err := store.New(dbPool).GetOAuthTokenWithUserByAccessHash(context.Background(), hashBearerToken(access)); err == nil {
		t.Error("tokens minted by a reused code must be revoked")
	}
}

func TestOAuthPKCEMismatch(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	const redirectURI = "https://ai.example/callback"
	_, sessionToken := createTestUser(t, "pkce@example.com")
	clientID := registerTestClient(t, redirectURI)
	verifier, _ := randomURLToken()
	code := authorizeAndConsent(t, clientID, redirectURI, pkceChallenge(verifier), sessionToken)

	wrong, _ := randomURLToken()
	rec := redeemCode(t, clientID, redirectURI, code, wrong)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "invalid_grant") {
		t.Fatalf("wrong verifier: status = %d, body %s", rec.Code, rec.Body.String())
	}
	// A failed PKCE attempt does not consume the code; the honest client wins.
	if ok := redeemCode(t, clientID, redirectURI, code, verifier); ok.Code != http.StatusOK {
		t.Errorf("legit redemption after failed attempt: status = %d", ok.Code)
	}
}

func TestOAuthAuthorizeNeverRedirectsBadClients(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	clientID := registerTestClient(t, "https://ai.example/callback")

	// Unregistered redirect_uri: HTML error page, no Location header.
	rec := doJSON(t, http.MethodGet, "/api/v1/oauth/authorize?"+url.Values{
		"client_id":             {clientID},
		"redirect_uri":          {"https://evil.example/steal"},
		"response_type":         {"code"},
		"code_challenge":        {"x"},
		"code_challenge_method": {"S256"},
	}.Encode(), "", nil)
	if rec.Code != http.StatusBadRequest || rec.Header().Get("Location") != "" {
		t.Fatalf("unregistered redirect: status = %d, location %q", rec.Code, rec.Header().Get("Location"))
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("expected HTML error page, got %q", ct)
	}

	// Registered redirect + bad scope: error goes BACK via redirect.
	rec = doJSON(t, http.MethodGet, "/api/v1/oauth/authorize?"+url.Values{
		"client_id":             {clientID},
		"redirect_uri":          {"https://ai.example/callback"},
		"response_type":         {"code"},
		"code_challenge":        {"x"},
		"code_challenge_method": {"S256"},
		"scope":                 {"admin:everything"},
		"state":                 {"s1"},
	}.Encode(), "", nil)
	if rec.Code != http.StatusFound {
		t.Fatalf("bad scope: status = %d", rec.Code)
	}
	loc, _ := url.Parse(rec.Header().Get("Location"))
	if loc.Query().Get("error") != "invalid_scope" || loc.Query().Get("state") != "s1" {
		t.Errorf("bad-scope redirect = %s", rec.Header().Get("Location"))
	}
}

func TestOAuthDenyAndSingleUseConsent(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	const redirectURI = "https://ai.example/callback"
	_, sessionToken := createTestUser(t, "deny@example.com")
	clientID := registerTestClient(t, redirectURI)

	authURL := "/api/v1/oauth/authorize?" + url.Values{
		"client_id": {clientID}, "redirect_uri": {redirectURI}, "response_type": {"code"},
		"code_challenge": {pkceChallenge("v")}, "code_challenge_method": {"S256"}, "state": {"d1"},
	}.Encode()
	rec := doJSON(t, http.MethodGet, authURL, "", nil)
	requestToken := strings.TrimPrefix(rec.Header().Get("Location"), "http://gt.test/connect/")

	dec := doJSON(t, http.MethodPost, "/api/v1/oauth/authorize/decision", sessionToken,
		map[string]any{"request_token": requestToken, "approve": false})
	if dec.Code != http.StatusOK {
		t.Fatalf("deny: status = %d", dec.Code)
	}
	redirectURL, _ := url.Parse(decode(t, dec)["redirect_url"].(string))
	if redirectURL.Query().Get("error") != "access_denied" || redirectURL.Query().Get("state") != "d1" {
		t.Errorf("deny redirect = %s", redirectURL)
	}

	// The consent handle is single-use: a second decision (or context) is gone.
	if again := doJSON(t, http.MethodPost, "/api/v1/oauth/authorize/decision", sessionToken,
		map[string]any{"request_token": requestToken, "approve": true}); again.Code != http.StatusGone {
		t.Errorf("re-used consent handle: status = %d, want 410", again.Code)
	}
	if ctx := doJSON(t, http.MethodPost, "/api/v1/oauth/authorize/context", "",
		map[string]any{"request_token": requestToken}); ctx.Code != http.StatusGone {
		t.Errorf("context after deny: status = %d, want 410", ctx.Code)
	}
}

func TestOAuthRegisterValidation(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	cases := []map[string]any{
		{"client_name": "X", "redirect_uris": []string{"https://a.example/cb#frag"}},
		{"client_name": "X", "redirect_uris": []string{"http://not-localhost.example/cb"}},
		{"client_name": "X", "redirect_uris": []string{}},
		{"client_name": "", "redirect_uris": []string{"https://a.example/cb"}},
	}
	for i, body := range cases {
		if rec := doJSON(t, http.MethodPost, "/api/v1/oauth/register", "", body); rec.Code != http.StatusBadRequest {
			t.Errorf("case %d: status = %d, want 400 (body %s)", i, rec.Code, rec.Body.String())
		}
	}
	// http://localhost is fine (MCP Inspector).
	if rec := doJSON(t, http.MethodPost, "/api/v1/oauth/register", "", map[string]any{
		"client_name": "Inspector", "redirect_uris": []string{"http://localhost:6274/callback"},
	}); rec.Code != http.StatusCreated {
		t.Errorf("localhost redirect: status = %d", rec.Code)
	}
}

func TestOAuthDisabledEverything404s(t *testing.T) {
	resetDB(t)
	// MCP_ENABLED deliberately unset.
	paths := []struct {
		method, path string
	}{
		{http.MethodGet, "/.well-known/oauth-protected-resource"},
		{http.MethodGet, "/.well-known/oauth-protected-resource/mcp"},
		{http.MethodGet, "/.well-known/oauth-authorization-server"},
		{http.MethodGet, "/.well-known/openid-configuration"},
		{http.MethodPost, "/api/v1/oauth/register"},
		{http.MethodGet, "/api/v1/oauth/authorize"},
		{http.MethodPost, "/api/v1/oauth/authorize/context"},
		{http.MethodPost, "/api/v1/oauth/token"},
	}
	for _, p := range paths {
		if rec := doJSON(t, p.method, p.path, "", nil); rec.Code != http.StatusNotFound {
			t.Errorf("%s %s: status = %d, want 404 while disabled", p.method, p.path, rec.Code)
		}
	}
}

func TestOAuthDiscoveryDocuments(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)

	rec := doJSON(t, http.MethodGet, "/.well-known/oauth-protected-resource/mcp", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("protected-resource: %d", rec.Code)
	}
	pr := decode(t, rec)
	if pr["resource"] != "http://gt.test/mcp" {
		t.Errorf("resource = %v", pr["resource"])
	}

	rec = doJSON(t, http.MethodGet, "/.well-known/oauth-authorization-server", "", nil)
	meta := decode(t, rec)
	if meta["issuer"] != "http://gt.test" ||
		meta["token_endpoint"] != "http://gt.test/api/v1/oauth/token" {
		t.Errorf("metadata = %v", meta)
	}
	methods := meta["code_challenge_methods_supported"].([]any)
	if len(methods) != 1 || methods[0] != "S256" {
		t.Errorf("code_challenge_methods = %v", methods)
	}
}

// A connector links an account in five rapid calls (register, authorize,
// context, decision, token) and vendors egress from shared IPs — the OAuth
// endpoints must not sit on the strict 5/min tier, where one user's link
// would throttle the next user's (found end-to-end against the dev stack).
func TestOAuthDanceSurvivesFromOneIP(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	const redirectURI = "https://ai.example/callback"
	ip := nextTestIP()

	// Three consecutive full links from the SAME address, as three users
	// behind one connector egress IP would produce.
	for i := 0; i < 3; i++ {
		user, sessionToken := createTestUser(t, fmt.Sprintf("shared%d@example.com", i))
		_ = user

		rec := doJSONFromIP(t, http.MethodPost, "/api/v1/oauth/register", "", ip, map[string]any{
			"client_name": "Shared AI", "redirect_uris": []string{redirectURI},
		})
		if rec.Code != http.StatusCreated {
			t.Fatalf("link %d register: status = %d, body %s", i, rec.Code, rec.Body.String())
		}
		clientID := decode(t, rec)["client_id"].(string)

		verifier, _ := randomURLToken()
		authURL := "/api/v1/oauth/authorize?" + url.Values{
			"client_id": {clientID}, "redirect_uri": {redirectURI}, "response_type": {"code"},
			"code_challenge": {pkceChallenge(verifier)}, "code_challenge_method": {"S256"},
		}.Encode()
		rec = doJSONFromIP(t, http.MethodGet, authURL, "", ip, nil)
		if rec.Code != http.StatusSeeOther {
			t.Fatalf("link %d authorize: status = %d", i, rec.Code)
		}
		requestToken := strings.TrimPrefix(rec.Header().Get("Location"), "http://gt.test/connect/")

		if rec = doJSONFromIP(t, http.MethodPost, "/api/v1/oauth/authorize/context", "", ip,
			map[string]any{"request_token": requestToken}); rec.Code != http.StatusOK {
			t.Fatalf("link %d context: status = %d", i, rec.Code)
		}
		rec = doJSONFromIP(t, http.MethodPost, "/api/v1/oauth/authorize/decision", sessionToken, ip,
			map[string]any{"request_token": requestToken, "approve": true})
		if rec.Code != http.StatusOK {
			t.Fatalf("link %d decision: status = %d, body %s", i, rec.Code, rec.Body.String())
		}
		redirectURL, _ := url.Parse(decode(t, rec)["redirect_url"].(string))
		code := redirectURL.Query().Get("code")

		req := httptest.NewRequest(http.MethodPost, "/api/v1/oauth/token", strings.NewReader(url.Values{
			"grant_type": {"authorization_code"}, "code": {code}, "code_verifier": {verifier},
			"client_id": {clientID}, "redirect_uri": {redirectURI},
		}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("X-Forwarded-For", ip)
		tokRec := httptest.NewRecorder()
		testRouter.ServeHTTP(tokRec, req)
		if tokRec.Code != http.StatusOK {
			t.Fatalf("link %d token: status = %d, body %s", i, tokRec.Code, tokRec.Body.String())
		}
	}
}
