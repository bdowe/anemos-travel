-- name: ListBookingOptionsByTrip :many
-- The whole trip's shortlist, ordered the way it renders: by leg (the client
-- groups on booking_todo_id), then manual position, then age.
SELECT * FROM booking_options
WHERE trip_id = $1
ORDER BY position ASC, created_at ASC;

-- name: ListBookingOptionsByTodo :many
SELECT * FROM booking_options
WHERE booking_todo_id = $1
ORDER BY position ASC, created_at ASC;

-- name: GetBookingOption :one
SELECT * FROM booking_options WHERE id = $1 AND trip_id = $2;

-- name: CountBookingOptionsByTodo :one
SELECT count(*) FROM booking_options WHERE booking_todo_id = $1;

-- name: CountBookingOptionsByTrip :one
SELECT count(*) FROM booking_options WHERE trip_id = $1;

-- name: CreateBookingOption :one
INSERT INTO booking_options (
    trip_id, booking_todo_id, title, subtitle, url, provider, notes, image_url,
    price, currency, start_date, end_date, origin, destination, mode, position)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15,
        COALESCE((SELECT max(position) + 1 FROM booking_options WHERE booking_todo_id = $2), 0))
RETURNING *;

-- name: UpdateBookingOption :one
-- Partial update (COALESCE sqlc.narg idiom, see query/trips.sql UpdateTrip).
-- COALESCE means fields can be overwritten but not cleared back to NULL.
--
-- The promoted_* columns are deliberately absent: "which option won" is set by
-- the choose transaction alone, never by a client PATCH. Same shape as
-- booking_todos.auto — one writer, named.
UPDATE booking_options
SET title       = COALESCE(sqlc.narg('title'), title),
    subtitle    = COALESCE(sqlc.narg('subtitle'), subtitle),
    url         = COALESCE(sqlc.narg('url'), url),
    provider    = COALESCE(sqlc.narg('provider'), provider),
    notes       = COALESCE(sqlc.narg('notes'), notes),
    image_url   = COALESCE(sqlc.narg('image_url'), image_url),
    price       = COALESCE(sqlc.narg('price'), price),
    currency    = COALESCE(sqlc.narg('currency'), currency),
    start_date  = COALESCE(sqlc.narg('start_date'), start_date),
    end_date    = COALESCE(sqlc.narg('end_date'), end_date),
    origin      = COALESCE(sqlc.narg('origin'), origin),
    destination = COALESCE(sqlc.narg('destination'), destination),
    mode        = COALESCE(sqlc.narg('mode'), mode)
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id')
RETURNING *;

-- name: DeleteBookingOption :execrows
-- Refuses a CHOSEN option. Removing a bookmark must not silently unbook a leg
-- and delete its expense as a side effect (docs/zen.md: errors should never
-- pass silently) — the handler turns the zero row count into a 409 telling the
-- caller to un-choose first.
DELETE FROM booking_options
WHERE id = $1 AND trip_id = $2
  AND promoted_accommodation_id IS NULL AND promoted_segment_id IS NULL;

-- name: ClearBookingTodoWinner :many
-- Un-stamps whichever option currently wins this leg. Runs first inside the
-- choose transaction so idx_booking_options_winner stays a backstop against a
-- concurrent double-choose rather than the mechanism, and returns the id so the
-- response can name what it replaced.
UPDATE booking_options
SET promoted_accommodation_id = NULL, promoted_segment_id = NULL
WHERE booking_todo_id = $1
  AND (promoted_accommodation_id IS NOT NULL OR promoted_segment_id IS NOT NULL)
RETURNING id;

-- name: SetBookingOptionPromotion :one
UPDATE booking_options
SET promoted_accommodation_id = $3, promoted_segment_id = $4
WHERE id = $1 AND trip_id = $2
RETURNING *;
