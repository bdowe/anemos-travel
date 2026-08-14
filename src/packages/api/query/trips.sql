-- name: CreateTrip :one
INSERT INTO trips (user_id, title, chat_id, summary, travel_mode, updated_by)
VALUES ($1, $2, $3, $4, $5, $1)
RETURNING *;

-- name: CreateItineraryItem :one
INSERT INTO itinerary_items (trip_id, position, name, place_id, address, latitude, longitude, category, time_of_day, city, day_trip_from, day, local_source_name, local_recommendation_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
RETURNING *;

-- name: ListTripsByOwner :many
SELECT * FROM trips WHERE user_id = $1 ORDER BY created_at DESC;

-- name: ListLatestTripsByOwner :many
-- One row per chat group (latest version), with how many versions exist and the
-- trip's distinct hub cities (day_trip_from ?? city) in first-appearance order
-- for a location summary. Legacy trips with NULL chat_id stand alone.
--
-- List-row enrichment invariant: the list payload stays ONE query — anything
-- added here must be a lateral / correlated subquery over indexed FKs (no
-- N+1, no per-trip HTTP fanout). Facts that can't be expressed that way
-- (trip health, budget totals) stay off the list. The shared EXISTS is the
-- HasActiveCollaborators predicate — keep the two in sync.
SELECT latest.id, latest.user_id, latest.created_at, latest.updated_at,
       latest.title, latest.start_date, latest.end_date,
       latest.chat_id, latest.version_count,
       COALESCE(c.cities, ARRAY[]::text[])::text[] AS cities,
       COALESCE(ic.item_count, 0)::int AS item_count,
       COALESCE(bt.total, 0)::int AS booking_total,
       COALESCE(bt.booked, 0)::int AS booking_booked,
       EXISTS (
         SELECT 1 FROM trip_collaborators tc
         WHERE tc.owner_id = latest.user_id AND tc.chat_id = latest.chat_id
           AND tc.revoked_at IS NULL
       )::bool AS shared
FROM (
  SELECT DISTINCT ON (COALESCE(chat_id, id::text))
         id, user_id, created_at, updated_at, title, start_date, end_date, chat_id,
         count(*) OVER (PARTITION BY COALESCE(chat_id, id::text)) AS version_count
  FROM trips WHERE trips.user_id = $1
  ORDER BY COALESCE(chat_id, id::text), created_at DESC
) latest
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
) c ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS item_count
  FROM itinerary_items ii2 WHERE ii2.trip_id = latest.id
) ic ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS total, count(*) FILTER (WHERE b.booked) AS booked
  FROM booking_todos b WHERE b.trip_id = latest.id
) bt ON true
ORDER BY latest.created_at DESC;

-- name: CountActiveTripLineagesByOwner :one
-- Active trips for the free-cap signal (specs/free-cap-instrumentation):
-- one per chat lineage, the same COALESCE(chat_id, id::text) grouping
-- ListLatestTripsByOwner's DISTINCT ON uses — new versions of an existing
-- lineage don't add to the count. All saved trips count as active (no
-- archived status exists today).
SELECT count(DISTINCT COALESCE(chat_id, id::text)) FROM trips WHERE user_id = $1;

-- name: TripLineageExists :one
-- Whether the owner already has any trip in this chat lineage. persistTrip
-- runs it inside the same transaction as its insert to distinguish a
-- brand-new lineage from a new version of an existing one: the free-cap
-- active_trips signal may only fire for new lineages (a version save never
-- moves the lineage count and can never emit —
-- specs/free-cap-instrumentation).
SELECT EXISTS(
  SELECT 1 FROM trips WHERE user_id = $1 AND chat_id = $2
) AS lineage_exists;

-- name: ListTripVersionsByChat :many
SELECT * FROM trips WHERE user_id = $1 AND chat_id = $2 ORDER BY created_at DESC;

-- name: GetTripByIDAndOwner :one
SELECT * FROM trips WHERE id = $1 AND user_id = $2;

-- name: GetItineraryItemsByTrip :many
SELECT * FROM itinerary_items WHERE trip_id = $1 ORDER BY position ASC;

-- name: ShiftItineraryItemPositions :exec
-- Opens a gap at the given position for an insert; the (trip_id, position)
-- index is non-unique, so the unordered update cannot collide.
UPDATE itinerary_items SET position = position + 1
WHERE trip_id = $1 AND position >= $2;

-- name: DeleteItineraryItemsByTrip :exec
DELETE FROM itinerary_items WHERE trip_id = $1;

-- name: UpdateItineraryItem :one
-- Partial update (COALESCE narg pattern, like UpdateTrip). Attribution columns
-- (local_source_name, local_recommendation_id) are deliberately not updatable —
-- they are snapshots written by the agent.
UPDATE itinerary_items
SET name        = COALESCE(sqlc.narg('name'), name),
    place_id    = COALESCE(sqlc.narg('place_id'), place_id),
    address     = COALESCE(sqlc.narg('address'), address),
    latitude    = COALESCE(sqlc.narg('latitude'), latitude),
    longitude   = COALESCE(sqlc.narg('longitude'), longitude),
    category    = COALESCE(sqlc.narg('category'), category),
    time_of_day = COALESCE(sqlc.narg('time_of_day'), time_of_day),
    city        = COALESCE(sqlc.narg('city'), city),
    day_trip_from = COALESCE(sqlc.narg('day_trip_from'), day_trip_from),
    day         = COALESCE(sqlc.narg('day'), day)
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id')
RETURNING *;

-- name: DeleteItineraryItem :execrows
DELETE FROM itinerary_items WHERE id = $1 AND trip_id = $2;

-- name: CloseItineraryItemPositionGap :exec
-- Compacts positions after a delete (mirror of ShiftItineraryItemPositions).
UPDATE itinerary_items SET position = position - 1
WHERE trip_id = $1 AND position > $2;

-- name: TouchTrip :exec
-- Content writes don't touch the trips row, so bump updated_at by hand and
-- record who made the edit (the "Updated by X" attribution on shared trips).
-- INVARIANT: only call from real user edits — never from passive load paths
-- like syncBookingTodos, or every reader looks like an editor and polling
-- clients chase each other's refreshes.
UPDATE trips SET updated_at = now(), updated_by = $2 WHERE id = $1;

-- name: GetTripStatusByID :one
-- Freshness poll for shared-trip clients: one cheap row, authorized for the
-- owner or any active collaborator on the row's lineage.
SELECT t.updated_at, t.updated_by,
       COALESCE(u.display_name, '')::text AS updated_by_name
FROM trips t
LEFT JOIN users u ON u.id = t.updated_by
WHERE t.id = $1
  AND (t.user_id = $2 OR EXISTS (
        SELECT 1 FROM trip_collaborators c
        WHERE c.user_id = $2 AND c.revoked_at IS NULL
          AND c.owner_id = t.user_id AND c.chat_id = t.chat_id));

-- name: HasActiveCollaborators :one
-- Whether anyone collaborates on this lineage — tells the owner's client the
-- trip is shared (worth polling for freshness).
SELECT EXISTS (
  SELECT 1 FROM trip_collaborators
  WHERE owner_id = $1 AND chat_id = $2 AND revoked_at IS NULL
)::bool;

-- name: GetTripForUpdate :one
-- Row-locks the trip for the duration of the transaction. Full-itinerary
-- rewrites (replaceTripSection) and reorders read-then-write the whole item
-- set; without this lock two concurrent writers interleave under READ
-- COMMITTED and both item sets survive the delete/reinsert.
SELECT * FROM trips WHERE id = $1 FOR UPDATE;

-- name: UpdateTrip :one
UPDATE trips
SET title      = COALESCE(sqlc.narg('title'), title),
    start_date = COALESCE(sqlc.narg('start_date'), start_date),
    end_date   = COALESCE(sqlc.narg('end_date'), end_date),
    chat_id    = COALESCE(sqlc.narg('chat_id'), chat_id),
    travel_mode = COALESCE(sqlc.narg('travel_mode'), travel_mode)
WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: SetTripTravelMode :exec
-- Authorization happens in the callers (checkBoundTripSession / editableTrip),
-- same as CreateSegment — no user_id scope here.
UPDATE trips SET travel_mode = $2 WHERE id = $1;

-- name: SetTripDates :exec
-- Authorization happens in the caller (runSetTripDatesTool's resolution
-- ladder), same as SetTripTravelMode — no user_id scope here, so editor
-- collaborators can shift a shared trip.
UPDATE trips SET start_date = $2, end_date = $3 WHERE id = $1;

-- name: DeleteTrip :execrows
-- Deletes the trip and, when it belongs to a chat group, all its versions.
-- Legacy trips (chat_id NULL) match only by id, so a single row is removed.
DELETE FROM trips t
WHERE t.user_id = sqlc.arg('user_id')
  AND (
    t.id = sqlc.arg('id')
    OR t.chat_id = (
      SELECT chat_id FROM trips
      WHERE id = sqlc.arg('id') AND user_id = sqlc.arg('user_id') AND chat_id IS NOT NULL
    )
  );
