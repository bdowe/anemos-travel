# MCP connector: plan trips inside ChatGPT / claude.ai

## Context

Track 2 of the external-AI plan (Track 1 was specs/import-trip-from-ai-chat).
Users already plan trips in ChatGPT and claude.ai on their own subscriptions.
Instead of asking them to paste the result into Golden Tempo, this feature
makes Golden Tempo a **connector** they add to their AI chat: ChatGPT
(Developer Mode custom connector, Plus and up; app-directory submission later)
and claude.ai (custom connector, Pro/Max) both speak MCP to a remote server we
host. Once a user links their Golden Tempo account (OAuth), the AI can create
trips directly in their account and search our locally-sourced
recommendations mid-conversation — the moat content, inside ChatGPT.

The user's AI subscription pays for every token of inference; our server only
executes tool calls. There is no way to bill our own backend's API calls to a
user's consumer subscription ("Sign in with Claude" does not exist; OpenAI's
equivalent is pilot-only) — the connector inversion is the only deep
integration available, and it is fully supported by both vendors.

## User Stories

- As a ChatGPT user, I add "Golden Tempo" as a connector, approve it once
  against my Golden Tempo account, and say "save this itinerary to Golden
  Tempo" — the trip appears in My Trips with a link I can click.
- As the same user, when I ask ChatGPT "where do locals actually eat in
  Lisbon?", the connector answers from Golden Tempo's curated local
  recommendations, credited to the local by name.
- As a claude.ai Pro user, I add the identical server URL as a custom
  connector and get the same experience.
- As a cautious user, I can see which apps are connected to my account in
  Settings and revoke one instantly.

## Acceptance Criteria

- [ ] The server passes MCP Inspector against a local stack: discovery,
      OAuth dance (DCR → authorize → consent → token), initialize,
      tools/list, tools/call.
- [ ] Adding `https://<host>/mcp` in ChatGPT Developer Mode and in claude.ai
      custom connectors completes account linking via the Flutter consent
      screen (sign-in included when signed out) and lists three tools.
- [ ] `create_trip` called by the AI produces a trip in the linked account
      (coordinates resolved via Places, unresolved places named in the result,
      never silently dropped) and returns a clickable trip URL.
- [ ] `search_local_recommendations` returns published local recs with
      attribution, mirroring the in-app agent tool.
- [ ] Tokens are hashed at rest; codes are single-use (reuse revokes the
      minted tokens); refresh rotates; PKCE S256 is enforced; redirect URIs
      are exact-match against the client's DCR registration.
- [ ] A "Connected apps" section in account settings lists grants
      (name, scopes, last used) and revoke kills the connector immediately.
- [ ] Everything is gated behind `MCP_ENABLED=true` — deploying the code with
      the flag unset exposes none of the new endpoints.

## API Surface

### Discovery & OAuth (provider role — we issue tokens to ChatGPT/claude.ai)

- `GET /.well-known/oauth-protected-resource[/mcp]` (RFC 9728): resource =
  `<PUBLIC_BASE_URL>/mcp`, authorization server = us, scopes
  `trips:write recs:read`.
- `GET /.well-known/oauth-authorization-server` (RFC 8414): endpoint URLs,
  `code_challenge_methods_supported: ["S256"]`,
  `token_endpoint_auth_methods_supported: ["none"]`.
- `POST /api/v1/oauth/register` (RFC 7591, open): `client_name` +
  `redirect_uris` (≤5; https or localhost) → `client_id`. Public clients only,
  no secrets.
- `GET /api/v1/oauth/authorize`: validates client/redirect/PKCE/scope; parks
  the request; 302 to the app at `/connect/<request-token>`. Invalid
  client/redirect renders an HTML error and **never redirects**.
- `POST /api/v1/oauth/authorize/context`: consent-screen data for a pending
  request (client_name, scopes) — the request token is the credential.
- `POST /api/v1/oauth/authorize/decision` (auth): `{request_token, approve}` →
  binds the signed-in user, upserts the grant, mints the code, returns the
  client redirect URL (or `error=access_denied` on deny).
- `POST /api/v1/oauth/token` (form-encoded): `authorization_code` (verify
  PKCE, single-use, client+redirect match) and `refresh_token` (rotate) →
  `{access_token, token_type, expires_in, refresh_token, scope}`.

### MCP

- `POST/GET/DELETE /mcp` — Streamable HTTP MCP server (stateless), Bearer
  auth; 401 carries `WWW-Authenticate: Bearer resource_metadata="…"` to drive
  client discovery/refresh. Tools:
  - `create_trip` (`trips:write`) — itinerary sans coordinates; server
    resolves via Places and persists; returns text + `{trip_id, url,
    resolved, dropped[]}`.
  - `search_local_recommendations` (`recs:read`) — same contract as the
    in-app agent tool.
  - `list_trips` (`trips:write`) — id/title/dates/url. (Originally also
    status, retired by specs/retire-trip-status.)
- `GET /api/v1/mcp/availability` — `{available: bool}` gate.

### Connected apps

- `GET /api/v1/oauth/connections` (auth) — `[{id, client_name, scopes,
  created_at, last_used_at}]`.
- `DELETE /api/v1/oauth/connections/{id}` (auth) — revoke grant + tokens.

## Data Model

Migration 00051: `oauth_clients` (DCR registrations), `oauth_auth_codes`
(two-phase: pending request → approved code, single-use), `oauth_grants` (the
consent record, unique per user+client, revocable), `oauth_tokens`
(access+refresh pairs, hashed, rotation on refresh, linked to their minting
code so code reuse revokes them). No changes to existing tables.

## UI Behavior

- `/connect/<request-token>` deep link → ConnectAppScreen: shows the
  requesting app's self-asserted name (with an "unverified app" caution),
  the two scopes in plain language, Approve / Deny. Signed out → the normal
  sign-in options first (email, Google, Apple), then consent. Expired/used
  request → "start over from ChatGPT" state.
- `trip/<id>` deep link → TripDetailScreen (lets `create_trip` return a URL
  that opens the app).
- Account settings gains a "Connected apps" section (list + revoke with
  confirmation). All copy en+es.

## Edge Cases & Error States

- Redirect URI not registered → HTML error page, no redirect (open-redirect
  guard). Unknown scope → `error=invalid_scope` redirect. Missing or non-S256
  PKCE → `error=invalid_request` redirect.
- Wrong PKCE verifier / expired / reused code → `400 invalid_grant`; reuse
  additionally revokes the tokens the code minted.
- Revoked grant → /mcp returns 401; ChatGPT prompts the user to reconnect.
- Trip cap reached → create_trip returns a tool error with the cap message.
- Places outage during create_trip → unresolved places dropped and named in
  the tool result; all-unresolved → tool error asking to retry.
- DB down → OAuth endpoints 503 (mirroring authMiddleware's 503-vs-401
  distinction); /mcp 503.
- `MCP_ENABLED` unset → all routes above 404/`{available:false}`.

## Out of Scope

- ChatGPT app-directory (Apps SDK) submission — later, its own spec.
- `get_trip` / itinerary-update tools (refinement via connector).
- Client secrets / confidential clients; scope picker UI.
- IP allowlisting (none exists today; Anthropic egress range documented in
  plan.md if that changes).

## Open Questions

None — decisions recorded in plan.md.
