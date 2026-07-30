package main

import (
	"strings"
	"time"
)

// oauth_provider_service.go: shared constants and token minting for the OAuth
// 2.1 provider behind the MCP connector (specs/mcp-connector). The endpoints
// live in oauth_provider_handler.go (PR 2); the /mcp surface consumes the
// tokens (PR 4). Storage posture matches sessions/email_tokens: the database
// only ever sees hashBearerToken() digests.

const (
	// Phase 1 handle: /oauth/authorize parks the validated request and sends
	// the browser to the app's consent screen carrying this token.
	oauthRequestTokenTTL = 10 * time.Minute
	// Authorization code (phase 2), redeemed at the token endpoint.
	oauthCodeTTL = 5 * time.Minute
	// Access tokens are short-lived; MCP clients refresh reactively on 401.
	oauthAccessTokenTTL = time.Hour
	// Refresh tokens rotate on every use; this is the idle ceiling before a
	// connector must be re-linked.
	oauthRefreshTokenTTL = 90 * 24 * time.Hour

	// Raw-token prefixes: leaked MCP credentials must be distinguishable at a
	// glance from hex session tokens (and from each other) in logs/reports.
	oauthRequestTokenPrefix = "gt_rq_"
	oauthCodePrefix         = "gt_ac_"
	oauthAccessTokenPrefix  = "gt_at_"
	oauthRefreshTokenPrefix = "gt_rt_"
)

// The fixed scope set. No picker UI — the consent screen lists both in plain
// language; tools enforce per-scope so granularity can grow later.
const (
	oauthScopeTripsWrite = "trips:write"
	oauthScopeRecsRead   = "recs:read"
)

var oauthSupportedScopes = map[string]bool{
	oauthScopeTripsWrite: true,
	oauthScopeRecsRead:   true,
}

// oauthDefaultScope is granted when a client requests no scope (both — the
// connector is useless without them).
var oauthDefaultScope = oauthScopeTripsWrite + " " + oauthScopeRecsRead

// normalizeOAuthScope validates a space-delimited scope request against the
// supported set. Empty input gets the default; any unknown token fails so the
// authorize endpoint can answer invalid_scope per RFC 6749 §3.3.
func normalizeOAuthScope(requested string) (string, bool) {
	fields := strings.Fields(requested)
	if len(fields) == 0 {
		return oauthDefaultScope, true
	}
	seen := map[string]bool{}
	var out []string
	for _, s := range fields {
		if !oauthSupportedScopes[s] {
			return "", false
		}
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return strings.Join(out, " "), true
}

// scopeGranted reports whether a granted (space-delimited) scope string
// includes the required scope — the per-tool enforcement check.
func scopeGranted(granted, required string) bool {
	for _, s := range strings.Fields(granted) {
		if s == required {
			return true
		}
	}
	return false
}

// newOAuthSecret mints a prefixed opaque token and its at-rest digest.
// The raw value goes to the client exactly once; only the hash is stored.
func newOAuthSecret(prefix string) (raw, hash string, err error) {
	tok, err := randomURLToken()
	if err != nil {
		return "", "", err
	}
	raw = prefix + tok
	return raw, hashBearerToken(raw), nil
}
