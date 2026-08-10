-- Batch statements for itinerary items (perf: replace per-row write loops
-- with one round trip). The per-row originals live in query/trips.sql.

-- name: SetItineraryItemPositionsBatch :exec
-- Batch twin of SetItineraryItemPosition: one round trip for the whole
-- reorder. ids and positions are parallel arrays; the trip_id scope mirrors
-- the per-row statement so a foreign id can never move another trip's row.
UPDATE itinerary_items i
SET position = u.pos
FROM (
    SELECT unnest(sqlc.arg(ids)::uuid[])      AS id,
           unnest(sqlc.arg(positions)::int[]) AS pos
) AS u
WHERE i.id = u.id AND i.trip_id = sqlc.arg(trip_id)::uuid;

-- name: CreateItineraryItems :copyfrom
-- Bulk twin of CreateItineraryItem (agent itinerary save — the per-row
-- results were discarded, so COPY is safe). Same column list; id/created_at
-- keep their defaults.
INSERT INTO itinerary_items (trip_id, position, name, place_id, address, latitude, longitude, category, time_of_day, city, day_trip_from, day, local_source_name, local_recommendation_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14);
