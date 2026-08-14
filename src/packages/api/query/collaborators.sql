-- name: CreateTripCollaborator :one
-- Idempotent join, upgrade-never-downgrade: redeeming an editor link (or
-- invite) upgrades an existing viewer membership; redeeming a viewer link as
-- an editor keeps editor. Returns the resulting role plus whether this call
-- created the membership (xmax = 0 only on a fresh insert), so callers can
-- fire first-join-only side effects without re-notifying on every re-redeem.
INSERT INTO trip_collaborators (chat_id, owner_id, user_id, role)
VALUES ($1, $2, $3, $4)
ON CONFLICT (owner_id, chat_id, user_id) WHERE revoked_at IS NULL
DO UPDATE SET role = CASE WHEN EXCLUDED.role = 'editor' THEN 'editor'
                          ELSE trip_collaborators.role END
RETURNING role, (xmax = 0)::boolean AS inserted;

-- name: ListCollaboratorsByOwnerAndChat :many
SELECT c.user_id, c.created_at, c.role, u.email,
       COALESCE(u.display_name, '')::text AS display_name
FROM trip_collaborators c
JOIN users u ON u.id = c.user_id
WHERE c.owner_id = $1 AND c.chat_id = $2 AND c.revoked_at IS NULL
ORDER BY c.created_at ASC;

-- name: RevokeTripCollaborator :execrows
UPDATE trip_collaborators SET revoked_at = now()
WHERE owner_id = $1 AND chat_id = $2 AND user_id = $3 AND revoked_at IS NULL;

-- name: GetEditableTripByID :one
-- The trip row when the caller may edit it: owner, or active editor
-- collaborator on the row's lineage. chat_id = NULL (legacy trips) never
-- matches a collaborator row, which is correct — they were never joinable.
SELECT t.* FROM trips t
WHERE t.id = $1
  AND (t.user_id = $2 OR EXISTS (
        SELECT 1 FROM trip_collaborators c
        WHERE c.user_id = $2 AND c.role = 'editor' AND c.revoked_at IS NULL
          AND c.owner_id = t.user_id AND c.chat_id = t.chat_id));

-- name: GetViewableTripByID :one
-- Read access: owner or ANY active collaborator (viewer follows included).
-- Returns the effective access so callers don't need a second lookup. The
-- partial unique index guarantees at most one active membership per person,
-- so the LEFT JOIN can't fan out.
SELECT t.*, CASE WHEN t.user_id = $2 THEN 'owner' ELSE c.role END::text AS access
FROM trips t
LEFT JOIN trip_collaborators c ON c.owner_id = t.user_id AND c.chat_id = t.chat_id
     AND c.user_id = $2 AND c.revoked_at IS NULL
WHERE t.id = $1 AND (t.user_id = $2 OR c.id IS NOT NULL);

-- name: ListLatestCollaboratedTripsForUser :many
-- "Shared with you": one row per collaborated lineage (latest version), same
-- shape as ListLatestTripsByOwner plus the owner's display name. Carries the
-- same item/booking count laterals (no shared EXISTS — a shared-with-me row
-- is by definition shared); the HANDLER nils booking fields for viewers
-- (the getTripHandler boundary), keeping this query role-agnostic.
SELECT latest.id, latest.user_id, latest.created_at, latest.updated_at,
       latest.title, latest.start_date, latest.end_date,
       latest.chat_id, latest.role, latest.version_count,
       COALESCE(c2.cities, ARRAY[]::text[])::text[] AS cities,
       COALESCE(u.display_name, '')::text AS owner_name,
       COALESCE(ic.item_count, 0)::int AS item_count,
       COALESCE(bt.total, 0)::int AS booking_total,
       COALESCE(bt.booked, 0)::int AS booking_booked
FROM (
  SELECT DISTINCT ON (t.chat_id)
         t.id, t.user_id, t.created_at, t.updated_at, t.title, t.start_date,
         t.end_date, t.chat_id, c.role,
         count(*) OVER (PARTITION BY t.chat_id) AS version_count
  FROM trips t
  JOIN trip_collaborators c ON c.owner_id = t.user_id AND c.chat_id = t.chat_id
  WHERE c.user_id = $1 AND c.revoked_at IS NULL
  ORDER BY t.chat_id, t.created_at DESC
) latest
JOIN users u ON u.id = latest.user_id
LEFT JOIN LATERAL (
  SELECT array_agg(hub.city ORDER BY hub.first_pos) AS cities
  FROM (
    SELECT COALESCE(NULLIF(ii.day_trip_from, ''), NULLIF(ii.city, '')) AS city,
           MIN(ii.position) AS first_pos
    FROM itinerary_items ii
    WHERE ii.trip_id = latest.id
      AND COALESCE(NULLIF(ii.day_trip_from, ''), NULLIF(ii.city, '')) IS NOT NULL
    GROUP BY COALESCE(NULLIF(ii.day_trip_from, ''), NULLIF(ii.city, ''))
  ) hub
) c2 ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS item_count
  FROM itinerary_items ii2 WHERE ii2.trip_id = latest.id
) ic ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS total, count(*) FILTER (WHERE b.booked) AS booked
  FROM booking_todos b WHERE b.trip_id = latest.id
) bt ON true
ORDER BY latest.created_at DESC;
