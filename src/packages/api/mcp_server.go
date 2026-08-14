package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"travel-route-planner/store"
)

// mcp_server.go: the remote MCP server ChatGPT (Developer Mode connectors) and
// claude.ai (custom connectors) talk to (specs/mcp-connector). Streamable HTTP
// at /mcp, Bearer-authenticated with the OAuth tokens minted in
// oauth_provider_handler.go; every tool call runs as the granting user.
//
// Stateless sessions on purpose: rather than relying on session state or
// context propagation, the SDK's per-request getServer hook builds a server
// whose tool handlers close over THIS request's authenticated caller. There is
// no path by which a tool can see another user's data.

// mcpCaller is the resolved identity behind one /mcp request.
type mcpCaller struct {
	userID  uuid.UUID
	grantID uuid.UUID
	scope   string
}

type mcpContextKey struct{}

func callerFromContext(ctx context.Context) (mcpCaller, bool) {
	c, ok := ctx.Value(mcpContextKey{}).(mcpCaller)
	return c, ok
}

// --- per-grant rate limiting --------------------------------------------------
//
// The IP tier can't bound a connector: ChatGPT's egress IPs are shared across
// every user, and a single grant can drive many calls. These limits are keyed
// by grant instead (in-memory, same posture as ipRateLimiter).

const (
	mcpToolCallsPerMinute = 30
	mcpToolCallBurst      = 10
	mcpCreateTripsPerDay  = 20
	// Tool results are capped well under the ~150K-char client ceiling.
	mcpMaxResultChars = 100000
)

type mcpGrantLimiter struct {
	mu      sync.Mutex
	windows map[string]*mcpWindow
}

type mcpWindow struct {
	windowStart time.Time
	count       int
	lastSeen    time.Time
}

func newMCPGrantLimiter() *mcpGrantLimiter {
	l := &mcpGrantLimiter{windows: make(map[string]*mcpWindow)}
	go l.janitor()
	return l
}

// allow implements a fixed-window counter: up to burst+perMinute calls in any
// one minute window per grant. Coarse on purpose — it exists to stop runaway
// loops, not to shape traffic.
func (l *mcpGrantLimiter) allow(key string, now time.Time, perMinute int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	w := l.windows[key]
	if w == nil || now.Sub(w.windowStart) >= time.Minute {
		w = &mcpWindow{windowStart: now}
		l.windows[key] = w
	}
	w.lastSeen = now
	w.count++
	return w.count <= perMinute+mcpToolCallBurst
}

func (l *mcpGrantLimiter) janitor() {
	for range time.Tick(10 * time.Minute) {
		cutoff := time.Now().Add(-time.Hour)
		l.mu.Lock()
		for k, w := range l.windows {
			if w.lastSeen.Before(cutoff) {
				delete(l.windows, k)
			}
		}
		l.mu.Unlock()
	}
}

func (l *mcpGrantLimiter) resetAll() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.windows = make(map[string]*mcpWindow)
}

var (
	mcpCallLimiter   = newMCPGrantLimiter()
	mcpCreateCounter = newDailyCounter()
)

// --- auth middleware -----------------------------------------------------------

// mcpUnauthorized answers with the WWW-Authenticate challenge MCP clients use
// to (re)discover our authorization server and refresh reactively — without
// this header a 401 is a dead end for ChatGPT/claude.ai.
func mcpUnauthorized(w http.ResponseWriter, reason string) {
	w.Header().Set("WWW-Authenticate",
		`Bearer resource_metadata="`+publicBaseURL()+`/.well-known/oauth-protected-resource/mcp"`)
	writeJSONError(w, http.StatusUnauthorized, reason)
}

// mcpAuthMiddleware resolves the Bearer token to its granting user, mirroring
// authMiddleware — including the 503-vs-401 distinction, so a database blip
// never looks like a revoked connector.
func mcpAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !mcpEnabled() {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		if dbPool == nil {
			writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
			return
		}
		token := bearerToken(r)
		if token == "" {
			mcpUnauthorized(w, "authorization required")
			return
		}
		q := store.New(dbPool)
		row, err := q.GetOAuthTokenWithUserByAccessHash(r.Context(), hashBearerToken(token))
		if err != nil {
			// A DB blip must not read as a revoked connector (the 503-vs-401
			// distinction authMiddleware makes for sessions).
			if dbErrorStatus(err) == http.StatusServiceUnavailable {
				writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
				return
			}
			mcpUnauthorized(w, "invalid or expired token")
			return
		}
		if !mcpCallLimiter.allow(row.GrantID.String(), time.Now(), mcpToolCallsPerMinute) {
			log.Printf("mcp rate limited grant=%s", row.GrantID)
			w.Header().Set("Retry-After", "60")
			writeJSONError(w, http.StatusTooManyRequests, "too many tool calls — slow down")
			return
		}
		// Feeds the Connected-apps "last used" column; best effort.
		safeGo("touchOAuthGrant", func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = store.New(dbPool).TouchOAuthGrant(ctx, row.GrantID)
		})

		caller := mcpCaller{userID: row.User.ID, grantID: row.GrantID, scope: row.Scope}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), mcpContextKey{}, caller)))
	})
}

// --- server construction --------------------------------------------------------

// newMCPHandler builds the Streamable HTTP handler. getServer runs per request,
// after mcpAuthMiddleware, so the caller is already known.
func newMCPHandler() http.Handler {
	handler := mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
		caller, _ := callerFromContext(r.Context())
		return newMCPServerFor(caller)
	}, &mcp.StreamableHTTPOptions{Stateless: true})
	return mcpAuthMiddleware(handler)
}

func newMCPServerFor(caller mcpCaller) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{
		Name:    "anemos",
		Title:   "Anemos",
		Version: os.Getenv("SENTRY_RELEASE"),
	}, nil)
	registerMCPTools(s, caller)
	return s
}

// truncateToolResult keeps a result under the client's size ceiling, saying so
// rather than silently cutting.
func truncateToolResult(s string) string {
	if len(s) <= mcpMaxResultChars {
		return s
	}
	return s[:mcpMaxResultChars] + "\n\n[result truncated]"
}

func toolError(msg string) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		IsError: true,
		Content: []mcp.Content{&mcp.TextContent{Text: msg}},
	}
}

func toolText(msg string) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: truncateToolResult(msg)}},
	}
}

// mcpAvailabilityHandler gates the connector UI/docs the same way the SSO
// buttons are gated.
func mcpAvailabilityHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"available": mcpEnabled() && dbPool != nil && strings.TrimSpace(publicBaseURL()) != "",
		"url":       publicBaseURL() + "/mcp",
	})
}
