-- name: ListBookingTodosByTrip :many
SELECT * FROM booking_todos WHERE trip_id = $1 ORDER BY position ASC, created_at ASC;

-- name: UpsertBookingTodo :one
-- KEPT deliberately though no handler calls it directly: it is the semantic
-- reference for UpsertBookingTodosBatch's column list / ON CONFLICT set, and
-- its generated Params struct is the row type the batch path builds
-- (booking_todo_handler.go). Delete only together with a handler refactor.
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

-- name: UpsertBookingTodosBatch :exec
-- Batch twin of UpsertBookingTodo: one round trip for the whole derived set.
-- Same column list and the same ON CONFLICT update set — booked, auto, and
-- mode are deliberately absent from DO UPDATE, so a re-sync preserves the
-- booked flag and the per-leg mode override (and never flips a row's auto
-- marker). Nullable date columns ride as
-- date[] with NULL elements; the nullable text columns ride as text[] plus a
-- parallel bool[] null mask, because sqlc maps text[] to []string, which
-- cannot carry NULL elements. The caller must dedupe todo_keys (last
-- occurrence wins, like sequential upserts would) — a single INSERT ... ON
-- CONFLICT cannot update the same row twice. (Parallel single-array unnest
-- calls in one SELECT list expand in lockstep for equal-length arrays;
-- sqlc's catalog lacks the multi-array unnest form.)
INSERT INTO booking_todos (trip_id, kind, todo_key, title, subtitle, provider, search_url, depart_date, return_date, position, auto)
SELECT sqlc.arg(trip_id)::uuid, u.kind, u.todo_key, u.title,
       CASE WHEN u.subtitle_null THEN NULL ELSE u.subtitle END,
       CASE WHEN u.provider_null THEN NULL ELSE u.provider END,
       CASE WHEN u.search_url_null THEN NULL ELSE u.search_url END,
       u.depart_date, u.return_date, u.position, true
FROM (
    SELECT unnest(sqlc.arg(kinds)::text[])            AS kind,
           unnest(sqlc.arg(todo_keys)::text[])        AS todo_key,
           unnest(sqlc.arg(titles)::text[])           AS title,
           unnest(sqlc.arg(subtitles)::text[])        AS subtitle,
           unnest(sqlc.arg(subtitle_nulls)::bool[])   AS subtitle_null,
           unnest(sqlc.arg(providers)::text[])        AS provider,
           unnest(sqlc.arg(provider_nulls)::bool[])   AS provider_null,
           unnest(sqlc.arg(search_urls)::text[])      AS search_url,
           unnest(sqlc.arg(search_url_nulls)::bool[]) AS search_url_null,
           unnest(sqlc.arg(depart_dates)::date[])     AS depart_date,
           unnest(sqlc.arg(return_dates)::date[])     AS return_date,
           unnest(sqlc.arg(positions)::int[])         AS position
) AS u
ON CONFLICT (trip_id, todo_key) DO UPDATE SET
    kind = EXCLUDED.kind,
    title = EXCLUDED.title,
    subtitle = EXCLUDED.subtitle,
    provider = EXCLUDED.provider,
    search_url = EXCLUDED.search_url,
    depart_date = EXCLUDED.depart_date,
    return_date = EXCLUDED.return_date,
    position = EXCLUDED.position;

-- name: DeleteStaleAutoBookingTodos :execrows
DELETE FROM booking_todos
WHERE trip_id = $1 AND auto = true AND todo_key <> ALL(@keys::text[]);

-- name: CreateBookingTodo :one
INSERT INTO booking_todos (trip_id, kind, todo_key, title, subtitle, provider, search_url, depart_date, return_date, position, auto)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, false)
RETURNING *;

-- name: SetBookingTodoBooked :one
UPDATE booking_todos SET booked = $3 WHERE id = $1 AND trip_id = $2 RETURNING *;

-- name: SetBookingTodoMode :one
-- Per-leg transport-mode override. Works on auto rows (like SetBookingTodoBooked
-- and unlike UpdateBookingTodo) and never touches booked/auto; provider and
-- search_url are rebuilt by the handler to match the new mode. transport-only
-- by design — a stay/other row 404s.
UPDATE booking_todos
SET mode = $3, provider = $4, search_url = $5
WHERE id = $1 AND trip_id = $2 AND kind = 'transport'
RETURNING *;

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

-- name: SetBookingTodoPositionsBatch :exec
-- One round trip for the whole reorder. ids and positions are parallel
-- arrays; every row is scoped to trip_id so a foreign id can never move
-- another trip's row.
UPDATE booking_todos b
SET position = u.pos
FROM (
    SELECT unnest(sqlc.arg(ids)::uuid[])      AS id,
           unnest(sqlc.arg(positions)::int[]) AS pos
) AS u
WHERE b.id = u.id AND b.trip_id = sqlc.arg(trip_id)::uuid;

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
