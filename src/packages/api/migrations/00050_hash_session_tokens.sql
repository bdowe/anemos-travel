-- +goose Up
-- Store session bearer tokens as SHA-256 digests instead of the raw token, so a
-- database read (SQL injection, a leaked backup) can no longer yield a usable
-- session. This matches how email/verify/reset/invite tokens are already stored.
--
-- Hashing the EXISTING rows in place keeps currently-signed-in users logged in:
-- the client still holds the raw token, and auth_service.go's hashBearerToken()
-- hashes it the same way on every lookup — encode(sha256(<utf8 bytes>),'hex'),
-- lowercase — so sha256(raw) computed in Go matches the digest stored here.
-- sessions.id is TEXT, so the 64-char hex digest fits with no type change.
UPDATE sessions SET id = encode(sha256(id::bytea), 'hex');

-- +goose Down
-- Hashing is one-way: the raw tokens cannot be recovered. Rolling back to code
-- that expects raw tokens would reject every stored (hashed) session, so clear
-- them — users simply sign in again.
DELETE FROM sessions;
