-- name: CreateAccommodation :one
INSERT INTO accommodations (trip_id, name, provider, url, address, latitude, longitude, check_in, check_out, price_note)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
RETURNING *;

-- name: ListAccommodationsByTrip :many
SELECT * FROM accommodations WHERE trip_id = $1 AND NOT dismissed ORDER BY position ASC, check_in ASC NULLS LAST, created_at ASC;

-- name: ListConfirmedAccommodationsByTrip :many
-- Viewer/share/duplicate surface: drafts (auto=true) are editor-only.
SELECT * FROM accommodations WHERE trip_id = $1 AND auto = false AND NOT dismissed ORDER BY position ASC, check_in ASC NULLS LAST, created_at ASC;

-- name: UpsertDraftAccommodation :execrows
-- The WHERE guard leaves confirmed (auto=false) and dismissed rows untouched,
-- so this must be :execrows — a skipped conflict returns no row.
INSERT INTO accommodations (trip_id, name, address, check_in, check_out, auto, auto_key)
VALUES ($1, $2, $3, $4, $5, true, $6)
ON CONFLICT (trip_id, auto_key) WHERE auto_key IS NOT NULL DO UPDATE SET
    name      = EXCLUDED.name,
    address   = EXCLUDED.address,
    check_in  = EXCLUDED.check_in,
    check_out = EXCLUDED.check_out
WHERE accommodations.auto AND NOT accommodations.dismissed;

-- name: DeleteStaleDraftAccommodations :execrows
-- Prunes drafts (and their tombstones) whose itinerary leg no longer exists;
-- never touches confirmed rows.
DELETE FROM accommodations
WHERE trip_id = $1 AND auto = true AND (auto_key IS NULL OR auto_key <> ALL(@keys::text[]));

-- name: DismissDraftAccommodation :execrows
UPDATE accommodations SET dismissed = true WHERE id = $1 AND trip_id = $2 AND auto = true;

-- name: UpdateAccommodation :one
-- Partial update (COALESCE sqlc.narg idiom, see query/trips.sql UpdateTrip).
-- Any edit confirms a draft (auto = false), taking it out of sync ownership.
-- COALESCE means fields can be overwritten but not cleared back to NULL.
UPDATE accommodations
SET name       = COALESCE(sqlc.narg('name'), name),
    provider   = COALESCE(sqlc.narg('provider'), provider),
    url        = COALESCE(sqlc.narg('url'), url),
    address    = COALESCE(sqlc.narg('address'), address),
    latitude   = COALESCE(sqlc.narg('latitude'), latitude),
    longitude  = COALESCE(sqlc.narg('longitude'), longitude),
    check_in   = COALESCE(sqlc.narg('check_in'), check_in),
    check_out  = COALESCE(sqlc.narg('check_out'), check_out),
    price_note = COALESCE(sqlc.narg('price_note'), price_note),
    booked     = COALESCE(sqlc.narg('booked'), booked),
    auto       = false
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id') AND NOT dismissed
RETURNING *;

-- name: SetAccommodationPosition :exec
UPDATE accommodations SET position = $3 WHERE id = $1 AND trip_id = $2;

-- name: DeleteAccommodation :execrows
DELETE FROM accommodations WHERE id = $1 AND trip_id = $2;

-- name: ShiftAccommodationDates :execrows
-- Whole-trip date shift (agent set_trip_dates). date + int is civil-date
-- arithmetic; NULL dates stay NULL. The WHERE keeps execrows an honest
-- count of rows that actually shifted.
UPDATE accommodations
SET check_in  = check_in  + sqlc.arg(days)::int,
    check_out = check_out + sqlc.arg(days)::int
WHERE trip_id = sqlc.arg(trip_id)
  AND (check_in IS NOT NULL OR check_out IS NOT NULL);
