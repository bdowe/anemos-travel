-- name: InsertNotification :one
-- Type-agnostic write: the caller supplies the discriminator and a payload bag
-- carrying everything the client needs to render this row without a join.
INSERT INTO notifications (user_id, type, payload, trip_id)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: ListNotificationsByUser :many
-- The whole feed for one user, newest first. No join — every row is
-- self-describing via payload, so any notification type reads the same way.
SELECT * FROM notifications
WHERE user_id = $1
ORDER BY created_at DESC, id DESC
LIMIT $2;

-- name: MarkNotificationsRead :execrows
-- Mark-all is the read model: opening the notification center clears the badge
-- wholesale. Still no per-notification variant — unlike DELETE, which has one:
-- a row you are done with is dismissed outright rather than marked read.
UPDATE notifications
SET read_at = now()
WHERE user_id = $1 AND read_at IS NULL;

-- name: CountUnreadNotifications :one
SELECT count(*) FROM notifications
WHERE user_id = $1 AND read_at IS NULL;

-- name: InsertCollabEditNotifications :execrows
-- Fan-out, self-gated, throttled write for "a collaborator edited a shared
-- trip". Resolves the trip's lineage and, ONLY when the actor is not the trip
-- owner (owner edits notify no one), inserts one collab_edit row per recipient
-- — the owner plus every OTHER active collaborator, excluding the actor.
-- Throttle: skip any recipient already told about this (trip, actor) within the
-- last 6h so an editing session coalesces into a single notification per
-- recipient rather than one per keystroke-batch. Owner-only/solo trips and
-- owner self-edits yield zero rows, so callers can fire this on every edit.
WITH src AS (
    SELECT tr.id AS trip_id, tr.user_id AS owner_id, tr.chat_id,
           tr.title AS trip_title,
           COALESCE(a.display_name, 'A collaborator')::text AS actor_name
    FROM trips tr
    LEFT JOIN users a ON a.id = @actor_id
    WHERE tr.id = @trip_id AND tr.user_id <> @actor_id
), recipients AS (
    SELECT src.owner_id AS user_id, src.trip_id, src.trip_title, src.actor_name
    FROM src
    UNION
    SELECT c.user_id, src.trip_id, src.trip_title, src.actor_name
    FROM src
    JOIN trip_collaborators c
      ON c.owner_id = src.owner_id AND c.chat_id = src.chat_id
    WHERE c.revoked_at IS NULL AND c.user_id <> @actor_id
), targets AS (
    SELECT rec.user_id, rec.trip_id, rec.trip_title, rec.actor_name
    FROM recipients rec
    WHERE rec.user_id <> @actor_id
      AND NOT EXISTS (
          SELECT 1 FROM notifications n
          WHERE n.user_id = rec.user_id
            AND n.type = 'collab_edit'
            AND n.trip_id = rec.trip_id
            AND n.payload->>'actor_name' = rec.actor_name
            AND n.created_at > now() - interval '6 hours'
      )
)
INSERT INTO notifications (user_id, type, payload, trip_id)
SELECT user_id, 'collab_edit',
       jsonb_build_object('actor_name', actor_name, 'trip_title', trip_title),
       trip_id
FROM targets;

-- name: DeleteNotificationsByUser :execrows
-- Clear-all: one user-scoped wholesale action, mirroring MarkNotificationsRead.
-- Hard delete — a notification is an ephemeral signal, not a record of account
-- activity. DeleteNotification below is the single-row sibling.
DELETE FROM notifications
WHERE user_id = $1;

-- name: DeleteNotification :execrows
-- Dismiss one row. Ownership is structural in the WHERE clause rather than a
-- separate fetch-then-check: a row owned by somebody else deletes nothing and
-- is therefore indistinguishable from one that does not exist, so the handler's
-- 404 cannot be used to probe which notification ids are real.
--
-- :execrows, not :exec — the affected count is what separates "deleted" from
-- "was never yours", and the handler needs that to choose 204 over 404.
DELETE FROM notifications
WHERE id = $1 AND user_id = $2;

-- name: DeleteOldReadNotifications :exec
-- Retention (janitor): read rows expire 45 days after they were SEEN (read_at,
-- not created_at), so "anything you've seen sticks around ~6 more weeks" is a
-- guarantee expressible to a user. read_at IS NOT NULL makes "unread never
-- expires" structural — an unseen signal must not vanish silently. No
-- supporting index on purpose: neither existing index covers a read_at range
-- scan, an hourly seq scan is fine at current scale, and a partial index would
-- cost the migration this feature deliberately avoids (precedent:
-- DeleteOldHealthSamples, also an unindexed interval scan).
DELETE FROM notifications
WHERE read_at IS NOT NULL
  AND read_at < now() - interval '45 days';
