-- +goose Up
-- OAuth 2.1 provider tables for the MCP connector (specs/mcp-connector):
-- ChatGPT/claude.ai register as public clients (DCR, PKCE-only — no client
-- secrets anywhere), users approve a consent screen once, and the resulting
-- tokens let the connector act as that user against /mcp. Deliberately
-- separate from auth_identities (sign-in identities we CONSUME) and sessions
-- (first-party logins, different lifetime): these are capability tokens we
-- ISSUE to third-party software. Every secret is stored as its SHA-256 hex
-- digest (auth_service.go hashBearerToken), same posture as sessions and
-- email_tokens.

-- Dynamic Client Registrations (RFC 7591). Open registration; client_name is
-- self-asserted (the consent screen says so). redirect_uris is the exact-match
-- allowlist for the authorize step — the open-redirect guard.
CREATE TABLE oauth_clients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_name TEXT NOT NULL,
    redirect_uris TEXT[] NOT NULL,
    token_endpoint_auth_method TEXT NOT NULL DEFAULT 'none',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ
);

-- One row per authorization attempt, two phases. Phase 1 (/oauth/authorize):
-- the request is validated and parked; request_token_hash is the opaque
-- handle the browser carries to the app's /connect/<request-id> consent
-- screen. Phase 2 (approve): user_id + code_hash are filled and the code goes
-- back to the client. code_used_at makes the code single-use.
CREATE TABLE oauth_auth_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL REFERENCES oauth_clients(id) ON DELETE CASCADE,
    request_token_hash TEXT NOT NULL UNIQUE,
    redirect_uri TEXT NOT NULL,
    scope TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT '',
    code_challenge TEXT NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    code_hash TEXT UNIQUE,
    approved_at TIMESTAMPTZ,
    code_used_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The consent record: one live grant per (user, client). Revoking sets
-- revoked_at (and revokes the grant's tokens); re-approving upserts the row
-- back to life. last_used_at feeds the Connected-apps UI.
CREATE TABLE oauth_grants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id UUID NOT NULL REFERENCES oauth_clients(id) ON DELETE CASCADE,
    scope TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    UNIQUE (user_id, client_id)
);

-- Access/refresh pairs. Refresh = rotation: the old row is revoked and a new
-- one inserted. auth_code_id links a pair to the code that minted it so that
-- authorization-code REUSE (a classic stolen-code signal) can revoke exactly
-- the tokens that code produced (RFC 6749 §4.1.2 guidance).
CREATE TABLE oauth_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    grant_id UUID NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
    auth_code_id UUID REFERENCES oauth_auth_codes(id) ON DELETE SET NULL,
    access_token_hash TEXT NOT NULL UNIQUE,
    refresh_token_hash TEXT NOT NULL UNIQUE,
    access_expires_at TIMESTAMPTZ NOT NULL,
    refresh_expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX oauth_auth_codes_client_idx ON oauth_auth_codes (client_id);
CREATE INDEX oauth_grants_user_idx ON oauth_grants (user_id);
CREATE INDEX oauth_tokens_grant_idx ON oauth_tokens (grant_id);
CREATE INDEX oauth_tokens_auth_code_idx ON oauth_tokens (auth_code_id);

-- +goose Down
DROP TABLE oauth_tokens;
DROP TABLE oauth_grants;
DROP TABLE oauth_auth_codes;
DROP TABLE oauth_clients;
