# Tasks: MCP connector

## PR 1 — persistence + helpers
- [x] `migrations/00051_mcp_oauth.sql` (4 tables, hashed secrets, code-reuse linkage)
- [x] `query/oauth.sql` + `make api-sqlc`
- [x] `oauth_provider_service.go` (TTLs, prefixes, scopes, `newOAuthSecret`) + unit tests
- [x] resetDB TRUNCATE additions

## PR 2 — OAuth provider
- [x] Well-known documents (RFC 9728 both paths, RFC 8414, openid-configuration alias)
- [x] `POST /oauth/register` (DCR, redirect-URI validation)
- [x] `GET /oauth/authorize` (park request, 302 to /connect/; HTML error for bad client/redirect)
- [x] `POST /oauth/authorize/context` + `POST /oauth/authorize/decision`
- [x] `POST /oauth/token` (S256 verify, single-use + reuse revocation, refresh rotation)
- [x] Integration tests: full dance + negative matrix

## PR 3 — Flutter consent
- [x] `connect/<request-token>` + `trip/<id>` routes in generateRoute
- [x] `ConnectAppScreen` (sign-in gate, consent, deny, expired states)
- [x] ARB strings en+es + regen

## PR 4 — MCP server
- [x] go-sdk dep; stateless StreamableHTTP handler at /mcp
- [x] `mcpAuthMiddleware` (Bearer→user, WWW-Authenticate, 503-vs-401)
- [x] Tools: `create_trip`, `search_local_recommendations`, `list_trips` (+ scope enforcement)
- [x] Per-grant rate limiter; 100K result cap; /mcp CORS
- [x] Integration tests via go-sdk client (incl. context-propagation check)

## PR 5 — gateway + env
- [x] nginx blocks (deployment snippet + development conf)
- [x] `MCP_ENABLED` in `.env.sample`s; `GET /api/v1/mcp/availability`
- [ ] MCP Inspector pass on dev stack; deploy; ChatGPT + claude.ai manual pass

## PR 6 — connected apps
- [ ] `GET/DELETE /api/v1/oauth/connections`
- [ ] Settings "Connected apps" section + revoke dialog + l10n
- [ ] Contract Parity table checked
