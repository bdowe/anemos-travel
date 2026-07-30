-- OAuth 2.1 provider queries for the MCP connector (specs/mcp-connector).
-- Every *_hash parameter is a SHA-256 hex digest (hashBearerToken) — raw
-- tokens never reach the database.

-- name: CreateOAuthClient :one
INSERT INTO oauth_clients (client_name, redirect_uris)
VALUES ($1, $2)
RETURNING *;

-- name: GetOAuthClient :one
SELECT * FROM oauth_clients WHERE id = $1;

-- name: TouchOAuthClient :exec
UPDATE oauth_clients SET last_used_at = now() WHERE id = $1;

-- name: CreateOAuthAuthRequest :one
INSERT INTO oauth_auth_codes
    (client_id, request_token_hash, redirect_uri, scope, state, code_challenge, expires_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: GetOAuthAuthRequestByRequestHash :one
SELECT ac.*, c.client_name
FROM oauth_auth_codes ac
JOIN oauth_clients c ON c.id = ac.client_id
WHERE ac.request_token_hash = $1 AND ac.expires_at > now();

-- ApproveOAuthAuthRequest binds the signed-in user and mints the code, but
-- only on a still-pending, unexpired request (approved_at IS NULL makes the
-- consent handle single-use).
-- name: ApproveOAuthAuthRequest :one
UPDATE oauth_auth_codes
SET user_id = $2, code_hash = $3, approved_at = now(), expires_at = $4
WHERE request_token_hash = $1 AND approved_at IS NULL AND expires_at > now()
RETURNING *;

-- name: DeleteOAuthAuthRequest :exec
DELETE FROM oauth_auth_codes WHERE request_token_hash = $1;

-- GetOAuthAuthCodeByCodeHash intentionally returns used/expired rows too —
-- the token endpoint must distinguish "unknown code" from "code reuse" (which
-- revokes the tokens the first use minted).
-- name: GetOAuthAuthCodeByCodeHash :one
SELECT * FROM oauth_auth_codes WHERE code_hash = $1;

-- name: MarkOAuthCodeUsed :exec
UPDATE oauth_auth_codes SET code_used_at = now() WHERE id = $1;

-- name: UpsertOAuthGrant :one
INSERT INTO oauth_grants (user_id, client_id, scope)
VALUES ($1, $2, $3)
ON CONFLICT (user_id, client_id)
DO UPDATE SET scope = EXCLUDED.scope, revoked_at = NULL
RETURNING *;

-- name: GetOAuthGrantByUserAndClient :one
SELECT * FROM oauth_grants WHERE user_id = $1 AND client_id = $2;

-- name: TouchOAuthGrant :exec
UPDATE oauth_grants SET last_used_at = now() WHERE id = $1;

-- ListOAuthConnectionsByUser powers the Connected-apps settings section.
-- name: ListOAuthConnectionsByUser :many
SELECT g.id, g.scope, g.created_at, g.last_used_at, c.client_name
FROM oauth_grants g
JOIN oauth_clients c ON c.id = g.client_id
WHERE g.user_id = $1 AND g.revoked_at IS NULL
ORDER BY g.created_at DESC;

-- RevokeOAuthGrant is owner-scoped (the WHERE user_id) — the Connected-apps
-- kill switch. Token revocation is a separate statement in the same tx.
-- name: RevokeOAuthGrant :one
UPDATE oauth_grants SET revoked_at = now()
WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
RETURNING *;

-- name: CreateOAuthTokenPair :one
INSERT INTO oauth_tokens
    (grant_id, auth_code_id, access_token_hash, refresh_token_hash, access_expires_at, refresh_expires_at)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- GetOAuthTokenWithUserByAccessHash is the /mcp auth lookup: token → grant →
-- user in one round trip, filtering every revocation/expiry dimension
-- (mirrors GetSessionWithUser).
-- name: GetOAuthTokenWithUserByAccessHash :one
SELECT t.id AS token_id, t.grant_id, g.scope, g.client_id,
       sqlc.embed(u)
FROM oauth_tokens t
JOIN oauth_grants g ON g.id = t.grant_id
JOIN users u ON u.id = g.user_id
WHERE t.access_token_hash = $1
  AND t.revoked_at IS NULL
  AND t.access_expires_at > now()
  AND g.revoked_at IS NULL;

-- name: GetOAuthTokenByRefreshHash :one
SELECT t.*, g.user_id, g.scope, g.client_id, g.revoked_at AS grant_revoked_at
FROM oauth_tokens t
JOIN oauth_grants g ON g.id = t.grant_id
WHERE t.refresh_token_hash = $1
  AND t.revoked_at IS NULL
  AND t.refresh_expires_at > now();

-- name: RevokeOAuthToken :exec
UPDATE oauth_tokens SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL;

-- name: RevokeOAuthTokensByGrant :exec
UPDATE oauth_tokens SET revoked_at = now() WHERE grant_id = $1 AND revoked_at IS NULL;

-- RevokeOAuthTokensByAuthCode backs the code-reuse response: a second
-- redemption of the same code revokes everything the first minted.
-- name: RevokeOAuthTokensByAuthCode :exec
UPDATE oauth_tokens SET revoked_at = now() WHERE auth_code_id = $1 AND revoked_at IS NULL;

-- Opportunistic janitors (the DeleteExpiredSessions pattern): auth requests
-- and codes are minutes-lived; token rows become garbage after refresh expiry.
-- name: DeleteExpiredOAuthAuthCodes :exec
DELETE FROM oauth_auth_codes
WHERE expires_at < now() - INTERVAL '1 day';

-- name: DeleteExpiredOAuthTokens :exec
DELETE FROM oauth_tokens
WHERE refresh_expires_at < now();
