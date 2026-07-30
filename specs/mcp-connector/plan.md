# Plan: MCP connector (remote MCP server + OAuth account linking)

## Technical Approach

```
ChatGPT                      Browser (user)                    API (Go)
  | GET /.well-known/oauth-protected-resource[/mcp] --------------->|
  | GET /.well-known/oauth-authorization-server ------------------->|
  | POST /api/v1/oauth/register (DCR, public client, no secret) --->|  -> {client_id}
  | open authorize URL --> | GET /api/v1/oauth/authorize?client_id&
  |                        |   redirect_uri&code_challenge(S256)&
  |                        |   state&scope&resource --------------->|  park pending request
  |                        | <- 302 {app}/connect/<request-token>   |
  |                        | Flutter ConnectAppScreen (sign in if   |
  |                        |   needed - email/Google/Apple work)    |
  |                        | POST /oauth/authorize/decision ------->|  bind user, grant, mint code
  |                        | <- {redirect_url: cb?code&state}       |
  | POST /api/v1/oauth/token (code+verifier+client_id) ------------>|  verify S256, issue tokens
  | POST /mcp (Bearer) initialize / tools/list / tools/call ------->|  token->user, run as user
```

Design decisions:
- **In-process, not a sidecar**: everything the tools need is a package-main
  singleton (`persistTrip`, `placesService`, `localRecsService`,
  `hashBearerToken`, `recordEvent`, `publicAppURL`); the server already runs
  `WriteTimeout: 0` (Streamable HTTP SSE needs it); `buildRouter()` keeps the
  whole dance testable via httptest. Root-level routes are precedented
  (`/health`): `/mcp` + `/.well-known/*`; OAuth under `/api/v1/oauth/*`
  (RFC 8414 metadata carries absolute URLs).
- **Smallest compliant OAuth**: public clients + PKCE S256 only (no secrets),
  open DCR, fixed scope set (`trips:write recs:read`), exact-match redirect
  URIs, hashed tokens (`gt_rq_`/`gt_ac_`/`gt_at_`/`gt_rt_` prefixes so leaks
  are identifiable), refresh rotation, code-reuse revocation.
- **Consent in the Flutter app** (deep link `/connect/<request-token>`), not a
  server HTML page: the app already has sessions plus email/Google/Apple
  sign-in; an HTML page could do none of that. `SsoCallbackScreen` is the
  template; the initial-routes collapse gotcha is already handled.
- **Do not reuse** `auth_identities` (sign-in identities, enumerated
  providers) or `sessions` (different lifetime): these are capability tokens
  we issue, in their own four tables.
- **Stateless MCP sessions**: tool handlers run on the HTTP request context
  where our authenticated user lives; ChatGPT and claude.ai both work
  sessionless. (Verify context propagation in PR 4's first test — it is the
  reason for choosing sessionless.)
- **Gate everything on `mcpConfigured()`** (`MCP_ENABLED=true` +
  `PUBLIC_BASE_URL` + dbPool), the `googleOAuthConfigured()` convention.

## Go API Changes

### PR 1 — persistence + helpers (this PR)
- `migrations/00051_mcp_oauth.sql`: `oauth_clients`, `oauth_auth_codes`
  (two-phase pending→approved, single-use), `oauth_grants` (unique
  user+client, revocable), `oauth_tokens` (hashed pairs, `auth_code_id`
  linkage for reuse-revocation).
- `query/oauth.sql` + `make api-sqlc` (never hand-edit `store/`).
- `oauth_provider_service.go`: TTLs, prefixes, scope
  normalization/enforcement, `newOAuthSecret`.
- resetDB TRUNCATE list gains the four tables.

### PR 2 — OAuth provider endpoints (`oauth_provider_handler.go`)
Well-known docs (both RFC 9728 path forms + RFC 8414 + openid-configuration
alias); `POST /oauth/register` (≤5 https/localhost redirect URIs); `GET
/oauth/authorize` (invalid client/redirect → HTML error, never redirect;
other failures → `error=` redirect; success → park + 302 to
`publicAppURL("connect/", token)`); `POST /oauth/authorize/context`;
`POST /oauth/authorize/decision` (authMiddleware; approve → upsert grant +
mint code; deny → access_denied; expired/used → 410); `POST /oauth/token`
(form-encoded; constant-time S256 compare via `pkceChallenge`; code reuse →
`RevokeOAuthTokensByAuthCode`; refresh rotation). Metadata on the general
limiter tier, the rest strict. Integration tests drive the full dance with a
locally computed PKCE pair.

### PR 4 — MCP server (`mcp_server.go`, `mcp_tools.go`)
Dep `github.com/modelcontextprotocol/go-sdk`. Stateless
`StreamableHTTPHandler` at `/mcp` wrapped in `mcpAuthMiddleware`
(Bearer → hash → `GetOAuthTokenWithUserByAccessHash` → user+scope in context;
401 with `WWW-Authenticate: Bearer resource_metadata=…`; 503-vs-401 DB
distinction; `TouchOAuthGrant`). Tools: `create_trip` (locations schema =
`itineraryLocationSchema` minus lat/lng/place_id/address, ≤60; Places
resolution mirroring `resolveImportedLocations`; `persistTrip` under
`chat-<token>`; `recordEvent("trip_created", source:"mcp")` + cap signal;
returns `publicAppURL("trip/", id)`), `search_local_recommendations` (same
name/description as the agent tool, via `localRecsService`, ≤50),
`list_trips`. Per-grant limiter (30 calls/min burst 10; `create_trip` 20/day)
cloned from the ipRateLimiter structure; 100K-char result cap; CORS for
`/mcp` (Mcp-Session-Id, Mcp-Protocol-Version headers).

### PR 5 — gateway + env
`dockerize/deployment/nginx/snippets/app-locations.conf` (+ development
`default.conf`): `location /mcp` (proxy_read_timeout 310s, proxy_buffering
off, XFF like /api/) + precise `/.well-known/oauth-*` and
openid-configuration blocks — not all of `/.well-known/`. `MCP_ENABLED` in
both `.env.sample`s; `GET /api/v1/mcp/availability`.

### PR 6 — connected apps
`oauth_connections_handler.go`: `GET /api/v1/oauth/connections`,
`DELETE /api/v1/oauth/connections/{id}` (revoke grant + tokens, owner-scoped).

## Flutter Changes

### PR 3
- `main.dart` `generateRoute`: `connect/<request-token>` → `ConnectAppScreen`;
  `trip/<id>` → `TripDetailScreen`.
- `screens/connect_app_screen.dart` (template `sso_callback_screen.dart`):
  fetch context → sign-in gate → client_name (+ "unverified app" caution) +
  plain-language scopes + Approve/Deny → POST decision → navigate browser to
  `redirect_url`. l10n en+es.

### PR 6
- "Connected apps" `SectionHeader` block in `account_settings_screen.dart`
  between Sessions and Language; revoke + confirm dialog; l10n en+es.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|---|---|---|---|---|
| client_name (context resp) | string | String | no | |
| scopes (context resp) | []string | List<String> | no | |
| request_token (decision req) | string | String | no | |
| approve (decision req) | bool | bool | no | |
| redirect_url (decision resp) | string | String | no | |
| id (connections item) | string | String | no | |
| client_name (connections item) | string | String | no | |
| scopes (connections item) | []string | List<String> | no | |
| created_at (connections item) | time.Time | DateTime | no | |
| last_used_at (connections item) | *time.Time | DateTime? | yes | |

(✓ column checked as each PR lands.)

## Cross-cutting

- Env: `MCP_ENABLED` (availability-gate convention). No IP filtering exists;
  if any is ever added, Anthropic's egress range 160.79.104.0/21 must be
  allowlisted for claude.ai connectors.
- nginx `client_max_body_size` already ≥ 20 MiB; MCP bodies are small.

## Verification

- PR-level Go integration tests (register → authorize → decision with a real
  session → S256 token exchange → /mcp initialize/tools/list/tools/call using
  the go-sdk's own client against httptest) + negative matrix (wrong
  verifier, code reuse revokes, redirect mismatch never redirects, 401
  WWW-Authenticate shape, revoked grant, scope enforcement, per-grant 429,
  trip-cap error through tools/call).
- Manual: `npx @modelcontextprotocol/inspector` against
  `http://localhost:3000/mcp`; then production with `MCP_ENABLED=true`:
  ChatGPT Settings → Connectors → Developer Mode → add `https://<host>/mcp`,
  link, plan a trip; same in claude.ai Settings → Connectors.
- Rollout: own account soak → friendly users (per-account Developer Mode
  adds) → Apps SDK submission later (own spec).
