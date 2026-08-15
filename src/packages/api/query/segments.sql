-- name: CreateSegment :one
INSERT INTO trip_segments (trip_id, mode, origin, destination, depart_date, arrive_date, provider, url, price_note, notes)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
RETURNING *;

-- name: ListSegmentsByTrip :many
SELECT * FROM trip_segments WHERE trip_id = $1 AND NOT dismissed ORDER BY position ASC, depart_date ASC NULLS LAST, created_at ASC;

-- name: ListConfirmedSegmentsByTrip :many
-- Viewer/share/duplicate surface: drafts (auto=true) are editor-only.
SELECT * FROM trip_segments WHERE trip_id = $1 AND auto = false AND NOT dismissed ORDER BY position ASC, depart_date ASC NULLS LAST, created_at ASC;

-- name: UpsertDraftSegment :execrows
-- The WHERE guard leaves confirmed (auto=false) and dismissed rows untouched,
-- so this must be :execrows — a skipped conflict returns no row.
INSERT INTO trip_segments (trip_id, mode, origin, destination, depart_date, auto, auto_key)
VALUES ($1, $2, $3, $4, $5, true, $6)
ON CONFLICT (trip_id, auto_key) WHERE auto_key IS NOT NULL DO UPDATE SET
    mode        = EXCLUDED.mode,
    origin      = EXCLUDED.origin,
    destination = EXCLUDED.destination,
    depart_date = EXCLUDED.depart_date
WHERE trip_segments.auto AND NOT trip_segments.dismissed;

-- name: DeleteStaleDraftSegments :execrows
-- Prunes drafts (and their tombstones) whose itinerary leg no longer exists;
-- never touches confirmed rows.
DELETE FROM trip_segments
WHERE trip_id = $1 AND auto = true AND (auto_key IS NULL OR auto_key <> ALL(@keys::text[]));

-- name: DismissDraftSegment :execrows
UPDATE trip_segments SET dismissed = true WHERE id = $1 AND trip_id = $2 AND auto = true;

-- name: UpdateSegment :one
-- Partial update (COALESCE sqlc.narg idiom, see query/trips.sql UpdateTrip).
-- Any edit confirms a draft (auto = false), taking it out of sync ownership.
-- COALESCE means fields can be overwritten but not cleared back to NULL.
UPDATE trip_segments
SET mode        = COALESCE(sqlc.narg('mode'), mode),
    origin      = COALESCE(sqlc.narg('origin'), origin),
    destination = COALESCE(sqlc.narg('destination'), destination),
    depart_date = COALESCE(sqlc.narg('depart_date'), depart_date),
    arrive_date = COALESCE(sqlc.narg('arrive_date'), arrive_date),
    provider    = COALESCE(sqlc.narg('provider'), provider),
    url         = COALESCE(sqlc.narg('url'), url),
    price_note  = COALESCE(sqlc.narg('price_note'), price_note),
    notes       = COALESCE(sqlc.narg('notes'), notes),
    booked      = COALESCE(sqlc.narg('booked'), booked),
    auto        = false
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id') AND NOT dismissed
RETURNING *;

-- name: SetSegmentPosition :exec
UPDATE trip_segments SET position = $3 WHERE id = $1 AND trip_id = $2;

-- name: DeleteSegment :execrows
DELETE FROM trip_segments WHERE id = $1 AND trip_id = $2;

-- name: ShiftSegmentDates :execrows
-- Whole-trip date shift (agent set_trip_dates); see ShiftAccommodationDates.
UPDATE trip_segments
SET depart_date = depart_date + sqlc.arg(days)::int,
    arrive_date = arrive_date + sqlc.arg(days)::int
WHERE trip_id = sqlc.arg(trip_id)
  AND (depart_date IS NOT NULL OR arrive_date IS NOT NULL);

-- name: PromoteSegmentFromOption :one
-- Materializes a chosen booking option (00065) as the leg's real transport.
-- Same contract as PromoteAccommodationFromOption — see its comment for why
-- this upserts on (trip_id, auto_key) with no auto guard, and why stamping
-- auto_key is what puts the row in its leg's slot instead of "Other bookings"
-- (the matcher tests `autoKey.endsWith('>><label>')` before any fuzzy match).
INSERT INTO trip_segments (trip_id, mode, origin, destination, depart_date,
                           arrive_date, provider, url, price_note, notes,
                           auto, auto_key, booked, dismissed, position)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, false, $11, true, false, 9999)
ON CONFLICT (trip_id, auto_key) WHERE auto_key IS NOT NULL DO UPDATE SET
    mode        = EXCLUDED.mode,
    origin      = EXCLUDED.origin,
    destination = EXCLUDED.destination,
    depart_date = EXCLUDED.depart_date,
    arrive_date = EXCLUDED.arrive_date,
    provider    = EXCLUDED.provider,
    url         = EXCLUDED.url,
    price_note  = EXCLUDED.price_note,
    notes       = EXCLUDED.notes,
    auto        = false,
    dismissed   = false,
    booked      = true
RETURNING *;
