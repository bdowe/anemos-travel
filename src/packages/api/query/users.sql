-- name: CreateUser :one
-- locale is the language negotiated on the signup request, so the very first
-- email (verification) is already in the traveler's language rather than
-- waiting for the client's first sync (specs/i18n-spanish).
INSERT INTO users (email, password_hash, display_name, locale)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetUserByEmail :one
SELECT * FROM users WHERE email = $1;

-- name: GetUserByID :one
SELECT * FROM users WHERE id = $1;

-- name: MarkUserOnboarded :one
UPDATE users SET onboarded_at = COALESCE(onboarded_at, now())
WHERE id = $1
RETURNING *;

-- name: UpdateUserPassword :exec
UPDATE users SET password_hash = $2 WHERE id = $1;

-- name: MarkUserEmailVerified :exec
UPDATE users SET email_verified_at = COALESCE(email_verified_at, now())
WHERE id = $1;

-- name: UpdateUserProfile :one
-- Partial account update: a NULL arg leaves that column untouched, so one query
-- serves a display-name edit, a locale sync, or both. Same shape as
-- SetUserEmailOptOut below. Locale is never cleared back to NULL — the client
-- always resolves "System default" to a concrete language before syncing.
UPDATE users SET
    display_name = COALESCE(sqlc.narg('display_name'), display_name),
    locale       = COALESCE(sqlc.narg('locale'), locale)
WHERE id = sqlc.arg('id')
RETURNING *;

-- name: SetUserEmailOptOut :one
-- Category-partial opt-out setter: a NULL arg leaves that flag untouched, so a
-- single query handles reminders-only, nudges-only, or all-at-once. Used by
-- both the one-click unsubscribe link and the account-settings PATCH.
UPDATE users SET
    reminders_opt_out = COALESCE(sqlc.narg('reminders_opt_out'), reminders_opt_out),
    nudges_opt_out    = COALESCE(sqlc.narg('nudges_opt_out'), nudges_opt_out)
WHERE id = sqlc.arg('id')
RETURNING *;

-- name: DeleteUser :execrows
DELETE FROM users WHERE id = $1;

-- name: GetUserDisplayNames :many
-- Batch display-name lookup for response attribution (owner name + last-editor
-- name on the trip view) — one round trip instead of N GetUserByID calls.
-- Array-param pattern per query/admin.sql / query/price_alerts.sql.
SELECT id, display_name FROM users WHERE id = ANY($1::uuid[]);

-- name: ListAdminUsers :many
-- All admin accounts (is_admin = true), for operational fan-out such as the
-- ops-health degradation alert. Returns just what an alert needs: id + email +
-- display name. Stable ordering by creation so the recipient list is
-- deterministic.
SELECT id, email, display_name
FROM users
WHERE is_admin = true
ORDER BY created_at ASC;
