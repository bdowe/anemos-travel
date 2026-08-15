package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"travel-route-planner/store"
)

// MCP server integration tests (specs/mcp-connector): the go-sdk's own client
// speaks to our handler over Streamable HTTP through the real router, so the
// protocol layer is exercised end to end rather than mocked.

// mcpTestServer starts the shared router on a real listener (the MCP client
// needs a URL) and returns its base.
func mcpTestServer(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(testRouter)
	t.Cleanup(srv.Close)
	return srv.URL
}

// linkedConnector runs the full OAuth dance and returns a live access token
// for a fresh user — the state a connected ChatGPT/claude.ai is in.
func linkedConnector(t *testing.T, email string) (store.User, string) {
	t.Helper()
	const redirectURI = "https://ai.example/callback"
	user, sessionToken := createTestUser(t, email)
	clientID := registerTestClient(t, redirectURI)
	verifier, err := randomURLToken()
	if err != nil {
		t.Fatal(err)
	}
	code := authorizeAndConsent(t, clientID, redirectURI, pkceChallenge(verifier), sessionToken)
	rec := redeemCode(t, clientID, redirectURI, code, verifier)
	if rec.Code != http.StatusOK {
		t.Fatalf("token exchange: status = %d, body %s", rec.Code, rec.Body.String())
	}
	return user, decode(t, rec)["access_token"].(string)
}

// mcpSession connects the go-sdk client with a bearer token.
func mcpSession(t *testing.T, baseURL, accessToken string) *mcp.ClientSession {
	t.Helper()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-ai", Version: "1"}, nil)
	transport := &mcp.StreamableClientTransport{
		Endpoint: baseURL + "/mcp",
		HTTPClient: &http.Client{Transport: bearerTransport{
			token: accessToken, base: http.DefaultTransport,
		}},
	}
	session, err := client.Connect(context.Background(), transport, nil)
	if err != nil {
		t.Fatalf("mcp connect: %v", err)
	}
	t.Cleanup(func() { _ = session.Close() })
	return session
}

type bearerTransport struct {
	token string
	base  http.RoundTripper
}

func (b bearerTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	if b.token != "" {
		r.Header.Set("Authorization", "Bearer "+b.token)
	}
	return b.base.RoundTrip(r)
}

func TestMCPToolsListRequiresAuth(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	base := mcpTestServer(t)

	// No token at all: 401 carrying the discovery challenge that tells the
	// client where to authenticate.
	req, _ := http.NewRequest(http.MethodPost, base+"/mcp", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", res.StatusCode)
	}
	challenge := res.Header.Get("WWW-Authenticate")
	if !strings.Contains(challenge, "resource_metadata=") ||
		!strings.Contains(challenge, "/.well-known/oauth-protected-resource/mcp") {
		t.Errorf("WWW-Authenticate = %q, want a resource_metadata challenge", challenge)
	}
}

func TestMCPListsThreeTools(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	base := mcpTestServer(t)
	_, token := linkedConnector(t, "tools@example.com")

	session := mcpSession(t, base, token)
	res, err := session.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("tools/list: %v", err)
	}
	got := map[string]bool{}
	for _, tool := range res.Tools {
		got[tool.Name] = true
	}
	for _, want := range []string{"create_trip", "search_local_recommendations", "list_trips"} {
		if !got[want] {
			t.Errorf("tool %q missing from tools/list (%v)", want, got)
		}
	}
}

// Both connector directories reject tools with missing or wrong annotations, so
// they are part of the contract, not decoration. The trap this guards: the SDK's
// DestructiveHint and OpenWorldHint are *bool with omitempty and a documented
// default of TRUE, so a nil is not "no opinion" — it ships absent and the client
// reads the dangerous meaning. These assertions run against what the CLIENT
// received, so an omitted hint arrives as nil and fails here.
func TestMCPToolsCarryDirectoryAnnotations(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	base := mcpTestServer(t)
	_, token := linkedConnector(t, "annotations@example.com")

	session := mcpSession(t, base, token)
	res, err := session.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("tools/list: %v", err)
	}

	want := map[string]struct {
		title       string
		readOnly    bool
		destructive bool
		openWorld   bool
	}{
		"create_trip":                  {"Save trip to Anemos", false, false, false},
		"search_local_recommendations": {"Search local recommendations", true, false, false},
		"list_trips":                   {"List saved trips", true, false, false},
	}

	seen := 0
	for _, tool := range res.Tools {
		exp, ok := want[tool.Name]
		if !ok {
			t.Errorf("unexpected tool %q — add its annotations to this test before shipping it", tool.Name)
			continue
		}
		seen++
		if tool.Title != exp.title {
			t.Errorf("%s: title = %q, want %q", tool.Name, tool.Title, exp.title)
		}
		a := tool.Annotations
		if a == nil {
			t.Errorf("%s: no annotations at all", tool.Name)
			continue
		}
		if a.Title != exp.title {
			t.Errorf("%s: annotations.title = %q, want %q", tool.Name, a.Title, exp.title)
		}
		if a.ReadOnlyHint != exp.readOnly {
			t.Errorf("%s: readOnlyHint = %v, want %v", tool.Name, a.ReadOnlyHint, exp.readOnly)
		}
		if a.DestructiveHint == nil {
			t.Errorf("%s: destructiveHint absent from the wire — a nil hint reads as TRUE", tool.Name)
		} else if *a.DestructiveHint != exp.destructive {
			t.Errorf("%s: destructiveHint = %v, want %v", tool.Name, *a.DestructiveHint, exp.destructive)
		}
		if a.OpenWorldHint == nil {
			t.Errorf("%s: openWorldHint absent from the wire — a nil hint reads as TRUE", tool.Name)
		} else if *a.OpenWorldHint != exp.openWorld {
			t.Errorf("%s: openWorldHint = %v, want %v", tool.Name, *a.OpenWorldHint, exp.openWorld)
		}
	}
	if seen != len(want) {
		t.Errorf("annotated %d tools, want %d", seen, len(want))
	}
}

// initialize is the first thing a directory reviewer's client sees. An empty
// version or absent instructions reads as an unfinished server.
func TestMCPInitializeAdvertisesIdentityAndInstructions(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	base := mcpTestServer(t)
	_, token := linkedConnector(t, "initialize@example.com")

	init := mcpSession(t, base, token).InitializeResult()
	if init == nil {
		t.Fatal("no InitializeResult")
	}
	// The instructions steer every conversation on the connector; naming the
	// tools keeps this honest if one is ever renamed.
	for _, want := range []string{"search_local_recommendations", "create_trip", "list_trips"} {
		if !strings.Contains(init.Instructions, want) {
			t.Errorf("instructions never mention %q: %q", want, init.Instructions)
		}
	}
	info := init.ServerInfo
	if info == nil {
		t.Fatal("no ServerInfo")
	}
	if info.Version == "" {
		t.Error("ServerInfo.Version is empty — SENTRY_RELEASE is unset here, so the fallback should apply")
	}
	if info.Description == "" {
		t.Error("ServerInfo.Description is empty")
	}
	if info.WebsiteURL == "" {
		t.Error("ServerInfo.WebsiteURL is empty")
	}
	if len(info.Icons) == 0 {
		t.Error("ServerInfo.Icons is empty")
	}
}

// The load-bearing test for the stateless design: a tool call must run as the
// user whose token authenticated THIS request, with no cross-talk.
func TestMCPCreateTripRunsAsTokenOwner(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	mcpCreateCounter.resetAll()
	swapCannedPlaces(t, nil)
	base := mcpTestServer(t)

	alice, aliceToken := linkedConnector(t, "alice@example.com")
	bob, bobToken := linkedConnector(t, "bob@example.com")

	call := func(token, title string) *mcp.CallToolResult {
		t.Helper()
		session := mcpSession(t, base, token)
		res, err := session.CallTool(context.Background(), &mcp.CallToolParams{
			Name: "create_trip",
			Arguments: map[string]any{
				"title": title,
				"locations": []map[string]any{
					{"name": "Belém Tower", "city": "Lisbon", "day": 1, "time_of_day": "morning", "category": "attraction"},
					{"name": "Time Out Market", "city": "Lisbon", "day": 1, "time_of_day": "evening", "category": "restaurant"},
				},
			},
		})
		if err != nil {
			t.Fatalf("tools/call: %v", err)
		}
		if res.IsError {
			t.Fatalf("tool error: %+v", res.Content)
		}
		return res
	}

	aliceRes := call(aliceToken, "Alice in Lisbon")
	call(bobToken, "Bob in Lisbon")

	q := store.New(dbPool)
	aliceTrips, _ := q.ListTripsByOwner(context.Background(), alice.ID)
	bobTrips, _ := q.ListTripsByOwner(context.Background(), bob.ID)
	if len(aliceTrips) != 1 || aliceTrips[0].Title != "Alice in Lisbon" {
		t.Fatalf("alice trips = %+v", aliceTrips)
	}
	if len(bobTrips) != 1 || bobTrips[0].Title != "Bob in Lisbon" {
		t.Fatalf("bob trips = %+v", bobTrips)
	}
	if aliceTrips[0].ChatID == nil || !strings.HasPrefix(*aliceTrips[0].ChatID, "chat-") {
		t.Errorf("chat lineage not minted: %v", aliceTrips[0].ChatID)
	}
	items, _ := q.GetItineraryItemsByTrip(context.Background(), aliceTrips[0].ID)
	if len(items) != 2 {
		t.Fatalf("itinerary items = %d, want 2", len(items))
	}
	for _, it := range items {
		if it.Latitude == 0 || it.Longitude == 0 {
			t.Errorf("%s: coordinates not resolved", it.Name)
		}
	}

	// The result text must carry a link the AI can show the traveler.
	text := mcpResultText(aliceRes)
	if !strings.Contains(text, "/trip/"+aliceTrips[0].ID.String()) {
		t.Errorf("result text missing trip URL: %q", text)
	}
}

// Unresolvable places must be named back to the model, never silently lost.
func TestMCPCreateTripNamesDroppedPlaces(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	mcpCreateCounter.resetAll()
	swapCannedPlaces(t, func(q string) bool { return strings.Contains(q, "Ghost") })
	base := mcpTestServer(t)
	_, token := linkedConnector(t, "dropped@example.com")

	session := mcpSession(t, base, token)
	res, err := session.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "create_trip",
		Arguments: map[string]any{
			"title": "Partly Real",
			"locations": []map[string]any{
				{"name": "Belém Tower", "city": "Lisbon", "day": 1},
				{"name": "Ghost Spot", "city": "Lisbon", "day": 1},
			},
		},
	})
	if err != nil {
		t.Fatalf("tools/call: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
	text := mcpResultText(res)
	if !strings.Contains(text, "Ghost Spot") {
		t.Errorf("dropped place must be named in the result: %q", text)
	}
}

func TestMCPRevokedGrantStopsWorking(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	mcpCallLimiter.resetAll()
	base := mcpTestServer(t)
	user, token := linkedConnector(t, "revoked@example.com")

	// Sanity: it works before revocation.
	mcpSession(t, base, token)

	q := store.New(dbPool)
	grants, err := q.ListOAuthConnectionsByUser(context.Background(), user.ID)
	if err != nil || len(grants) != 1 {
		t.Fatalf("connections = %v (%v)", grants, err)
	}
	if _, err := q.RevokeOAuthGrant(context.Background(), store.RevokeOAuthGrantParams{
		ID: grants[0].ID, UserID: user.ID,
	}); err != nil {
		t.Fatal(err)
	}

	req, _ := http.NewRequest(http.MethodPost, base+"/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after revoke: status = %d, want 401", res.StatusCode)
	}
}

func TestMCPDisabled404s(t *testing.T) {
	resetDB(t)
	// MCP_ENABLED deliberately unset.
	base := mcpTestServer(t)
	res, err := http.Post(base+"/mcp", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 while disabled", res.StatusCode)
	}

	rec := doJSON(t, http.MethodGet, "/api/v1/mcp/availability", "", nil)
	if avail := decode(t, rec)["available"]; avail != false {
		t.Errorf("availability = %v, want false", avail)
	}
}

func TestMCPAvailabilityWhenEnabled(t *testing.T) {
	resetDB(t)
	mcpTestEnv(t)
	rec := doJSON(t, http.MethodGet, "/api/v1/mcp/availability", "", nil)
	body := decode(t, rec)
	if body["available"] != true {
		t.Errorf("available = %v, want true", body["available"])
	}
	if body["url"] != "http://gt.test/mcp" {
		t.Errorf("url = %v", body["url"])
	}
}

// mcpResultText concatenates the text content of a tool result.
func mcpResultText(res *mcp.CallToolResult) string {
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String()
}
