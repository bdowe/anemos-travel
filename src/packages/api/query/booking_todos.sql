-- name: ListBookingTodosByTrip :many
SELECT * FROM booking_todos WHERE trip_id = $1 ORDER BY position ASC, created_at ASC;

-- name: UpsertBookingTodo :one
INSERT INTO booking_todos (trip_id, kind, todo_key, title, subtitle, provider, search_url, depart_date, return_date, position, auto)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, true)
ON CONFLICT (trip_id, todo_key) DO UPDATE SET
    kind = EXCLUDED.kind,
    title = EXCLUDED.title,
    subtitle = EXCLUDED.subtitle,
    provider = EXCLUDED.provider,
    search_url = EXCLUDED.search_url,
    depart_date = EXCLUDED.depart_date,
    return_date = EXCLUDED.return_date,
    position = EXCLUDED.position
RETURNING *;

-- name: DeleteStaleAutoBookingTodos :execrows
DELETE FROM booking_todos
WHERE trip_id = $1 AND auto = true AND todo_key <> ALL(@keys::text[]);

-- name: CreateBookingTodo :one
INSERT INTO booking_todos (trip_id, kind, todo_key, title, subtitle, provider, search_url, depart_date, return_date, position, auto)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, false)
RETURNING *;

-- name: SetBookingTodoBooked :one
UPDATE booking_todos SET booked = $3 WHERE id = $1 AND trip_id = $2 RETURNING *;

-- name: UpdateBookingTodo :one
-- Partial update (COALESCE sqlc.narg idiom, see query/trips.sql UpdateTrip).
-- auto = false only: auto rows are owned by the client's itinerary sync and
-- would be overwritten on the next sync. COALESCE means fields can be
-- overwritten but not cleared back to NULL.
UPDATE booking_todos
SET kind        = COALESCE(sqlc.narg('kind'), kind),
    title       = COALESCE(sqlc.narg('title'), title),
    subtitle    = COALESCE(sqlc.narg('subtitle'), subtitle),
    depart_date = COALESCE(sqlc.narg('depart_date'), depart_date),
    return_date = COALESCE(sqlc.narg('return_date'), return_date),
    search_url  = COALESCE(sqlc.narg('search_url'), search_url),
    provider    = COALESCE(sqlc.narg('provider'), provider),
    booked      = COALESCE(sqlc.narg('booked'), booked)
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id') AND auto = false
RETURNING *;

-- name: SetBookingTodoPosition :exec
UPDATE booking_todos SET position = $3 WHERE id = $1 AND trip_id = $2;

-- name: DeleteBookingTodoNonAuto :execrows
DELETE FROM booking_todos WHERE id = $1 AND trip_id = $2 AND auto = false;

-- name: DeleteBookingTodo :execrows
DELETE FROM booking_todos WHERE id = $1 AND trip_id = $2;

-- name: ShiftBookingTodoDates :execrows
-- Whole-trip date shift (agent set_trip_dates); see ShiftAccommodationDates.
UPDATE booking_todos
SET depart_date = depart_date + sqlc.arg(days)::int,
    return_date = return_date + sqlc.arg(days)::int
WHERE trip_id = sqlc.arg(trip_id)
  AND (depart_date IS NOT NULL OR return_date IS NOT NULL);
