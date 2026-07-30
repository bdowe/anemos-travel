package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"travel-route-planner/store"
)

// Connected-apps API (specs/mcp-connector): listing is owner-scoped, and
// revoking must kill the grant AND its tokens in one shot — a half-revoked
// connection would keep working until each access token expired.

func TestOAuthConnectionsListAndRevoke(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	base := mcpTestServer(t)

	user, accessToken := linkedConnector(t, "conn@example.com")
	sessionToken := newSessionFor(t, user)

	rec := doJSON(t, http.MethodGet, "/api/v1/oauth/connections", sessionToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list: status = %d, body %s", rec.Code, rec.Body.String())
	}
	list := decodeList(t, rec)
	if len(list) != 1 {
		t.Fatalf("connections = %d, want 1 (%s)", len(list), rec.Body.String())
	}
	conn := list[0]
	if conn["client_name"] != "Test AI" {
		t.Errorf("client_name = %v", conn["client_name"])
	}
	scopes := conn["scopes"].([]any)
	if len(scopes) != 2 {
		t.Errorf("scopes = %v, want both", scopes)
	}

	// Revoke, then the connector's token must stop working immediately.
	del := doJSON(t, http.MethodDelete, "/api/v1/oauth/connections/"+conn["id"].(string), sessionToken, nil)
	if del.Code != http.StatusNoContent {
		t.Fatalf("revoke: status = %d, body %s", del.Code, del.Body.String())
	}
	req, _ := http.NewRequest(http.MethodPost, base+"/mcp",
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+accessToken)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after revoke: /mcp status = %d, want 401", res.StatusCode)
	}

	// And the revoked grant disappears from the list.
	rec = doJSON(t, http.MethodGet, "/api/v1/oauth/connections", sessionToken, nil)
	if list = decodeList(t, rec); len(list) != 0 {
		t.Errorf("connections after revoke = %d, want 0", len(list))
	}
}

func TestOAuthConnectionsAreOwnerScoped(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	mcpTestServer(t)

	owner, _ := linkedConnector(t, "owner@example.com")
	ownerSession := newSessionFor(t, owner)
	_, strangerSession := createTestUser(t, "stranger@example.com")

	rec := doJSON(t, http.MethodGet, "/api/v1/oauth/connections", ownerSession, nil)
	connID := decodeList(t, rec)[0]["id"].(string)

	// A stranger sees nothing and cannot revoke someone else's connection.
	rec = doJSON(t, http.MethodGet, "/api/v1/oauth/connections", strangerSession, nil)
	if strangerList := decodeList(t, rec); len(strangerList) != 0 {
		t.Errorf("stranger sees %d connections, want 0", len(strangerList))
	}
	del := doJSON(t, http.MethodDelete, "/api/v1/oauth/connections/"+connID, strangerSession, nil)
	if del.Code != http.StatusNotFound {
		t.Fatalf("stranger revoke: status = %d, want 404", del.Code)
	}
	// Unauthenticated too.
	if anon := doJSON(t, http.MethodGet, "/api/v1/oauth/connections", "", nil); anon.Code != http.StatusUnauthorized {
		t.Errorf("anonymous list: status = %d, want 401", anon.Code)
	}
}

// newSessionFor mints a first-party session for an existing user —
// linkedConnector returns the connector's access token, which is a different
// credential entirely.
func newSessionFor(t *testing.T, u store.User) string {
	t.Helper()
	token, err := issueSession(context.Background(), store.New(dbPool), u.ID)
	if err != nil {
		t.Fatalf("issueSession: %v", err)
	}
	return token
}

// decodeList unmarshals a JSON array response.
func decodeList(t *testing.T, rec *httptest.ResponseRecorder) []map[string]any {
	t.Helper()
	var out []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return out
}
