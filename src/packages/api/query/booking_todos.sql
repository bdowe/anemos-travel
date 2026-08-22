-- name: ListBookingTodosByTrip :many
SELECT * FROM booking_todos WHERE trip_id = $1 ORDER BY position ASC, created_at ASC;

-- name: UpsertBookingTodo :one
-- KEPT deliberately though no handler calls it directly: it is the semantic
-- reference for UpsertBookingTodosBatch's column list / ON CONFLICT set, and
-- its generated Params struct is the row type the batch path builds
-- (booking_todo_handler.go). Delete only together with a handler refactor.
--
-- role/origin_label/destination_label (00064) are CONTENT, like title: they
-- ride the DO UPDATE set so a re-sync refreshes them. So does derived_mode
-- (00068) — what the server worked out for the leg, refreshed alongside the
-- provider and search_url it decides. What must never join the set is
-- booked/auto/mode — that exclusion is the whole preservation contract, and
-- it is what lets a changed departure airport rewrite a home leg in place.
INSERT INTO booking_todos (trip_id, kind, todo_key, title, subtitle, provider, search_url, depart_date, return_date, position, auto, role, origin_label, destination_label, derived_mode)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, true, $11, $12, $13, $14)
ON CONFLICT (trip_id, todo_key) DO UPDATE SET
    kind = EXCLUDED.kind,
    title = EXCLUDED.title,
    subtitle = EXCLUDED.subtitle,
    provider = EXCLUDED.provider,
    search_url = EXCLUDED.search_url,
    depart_date = EXCLUDED.depart_date,
    return_date = EXCLUDED.return_date,
    position = EXCLUDED.position,
    role = EXCLUDED.role,
    origin_label = EXCLUDED.origin_label,
    destination_label = EXCLUDED.destination_label,
    derived_mode = EXCLUDED.derived_mode
RETURNING *;

-- name: UpsertBookingTodosBatch :exec
-- Batch twin of UpsertBookingTodo: one round trip for the whole derived set.
-- Same column list and the same ON CONFLICT update set — booked, auto, and
-- mode are deliberately absent from DO UPDATE, so a re-sync preserves the
-- booked flag and the per-leg mode override (and never flips a row's auto
-- marker). derived_mode is NOT one of them: it is the server's own answer for
-- the leg and is refreshed on every sync, exactly like provider and search_url,
-- which the same derivation decides. Nullable date columns ride as
-- date[] with NULL elements; the nullable text columns ride as text[] plus a
-- parallel bool[] null mask, because sqlc maps text[] to []string, which
-- cannot carry NULL elements. The caller must dedupe todo_keys (last
-- occurrence wins, like sequential upserts would) — a single INSERT ... ON
-- CONFLICT cannot update the same row twice. (Parallel single-array unnest
-- calls in one SELECT list expand in lockstep for equal-length arrays;
-- sqlc's catalog lacks the multi-array unnest form.)
INSERT INTO booking_todos (trip_id, kind, todo_key, title, subtitle, provider, search_url, depart_date, return_date, position, auto, role, origin_label, destination_label, derived_mode)
SELECT sqlc.arg(trip_id)::uuid, u.kind, u.todo_key, u.title,
       CASE WHEN u.subtitle_null THEN NULL ELSE u.subtitle END,
       CASE WHEN u.provider_null THEN NULL ELSE u.provider END,
       CASE WHEN u.search_url_null THEN NULL ELSE u.search_url END,
       u.depart_date, u.return_date, u.position, true,
       u.role,
       -- A label has no meaningful empty value, so NULLIF carries the "this
       -- row has no origin" case (every stay row) without a third null mask.
       -- Same for derived_mode: a stay leg has none.
       NULLIF(u.origin_label, ''), NULLIF(u.destination_label, ''),
       NULLIF(u.derived_mode, '')
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
           unnest(sqlc.arg(positions)::int[])         AS position,
           unnest(sqlc.arg(roles)::text[])            AS role,
           unnest(sqlc.arg(origin_labels)::text[])    AS origin_label,
           unnest(sqlc.arg(destination_labels)::text[]) AS destination_label,
           unnest(sqlc.arg(derived_modes)::text[])    AS derived_mode
) AS u
ON CONFLICT (trip_id, todo_key) DO UPDATE SET
    kind = EXCLUDED.kind,
    title = EXCLUDED.title,
    subtitle = EXCLUDED.subtitle,
    provider = EXCLUDED.provider,
    search_url = EXCLUDED.search_url,
    depart_date = EXCLUDED.depart_date,
    return_date = EXCLUDED.return_date,
    position = EXCLUDED.position,
    role = EXCLUDED.role,
    origin_label = EXCLUDED.origin_label,
    destination_label = EXCLUDED.destination_label,
    derived_mode = EXCLUDED.derived_mode;

-- name: AdoptLegacyHomeBookingTodo :execrows
-- Renames a home leg still stored under its endpoint-labelled key onto the
-- canonical @home identity, in place.
--
-- Migration 00064 backfills these, so this is the belt to that migration's
-- braces: it also catches a row written by an older binary during the deploy
-- itself, and it means a failed or skipped backfill degrades to "the next sync
-- fixes it" rather than to orphaned rows. Without it a legacy row would simply
-- fall outside the posted key set and be pruned — taking its booked flag with
-- it, which is the whole bug.
--
-- Renames only when nothing already holds the canonical key, so it can never
-- violate idx_booking_todos_trip_key; the caller's upsert then writes the
-- content either way.
UPDATE booking_todos b
SET todo_key = sqlc.arg('new_key')::text
WHERE b.trip_id = sqlc.arg('trip_id') AND b.todo_key = sqlc.arg('old_key')::text
  AND b.auto = true AND b.kind = 'transport'
  AND NOT EXISTS (
        SELECT 1 FROM booking_todos x
        WHERE x.trip_id = b.trip_id AND x.todo_key = sqlc.arg('new_key')::text);

-- name: ListHomeBookingTodos :many
-- The trip's two journey-endpoint rows, in checklist order. Used when the
-- trip's endpoints change so their labels can be refreshed immediately rather
-- than at the next client sync — a tool that reports "the checklist now reads
-- ALB → Amsterdam" has to have made that true before it says so.
SELECT * FROM booking_todos
WHERE trip_id = $1 AND auto = true AND role IN ('home_outbound', 'home_return')
ORDER BY position ASC, created_at ASC;

-- name: RelabelHomeBookingTodo :one
-- Repoints ONE journey-endpoint row at a new airport. Content only: the row
-- keeps its id, so booked, mode, position and any trip_expenses row linked by
-- source_id ride along untouched — which is the entire reason the key stopped
-- containing the airport (00064). todo_key is deliberately absent: the @home
-- identity does not move when the label does.
UPDATE booking_todos
SET origin_label = sqlc.narg('origin_label'),
    destination_label = sqlc.narg('destination_label'),
    title = sqlc.arg('title'),
    search_url = sqlc.narg('search_url'),
    provider = sqlc.narg('provider')
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id')
RETURNING *;

-- name: DemoteStaleAutoBookingTodos :execrows
-- Half of the prune, and it MUST run before DeleteStaleAutoBookingTodos.
--
-- A stale auto row that carries traveler state is not garbage — it is a booked
-- flight, a per-leg mode override, or the source of a budget expense. Deleting
-- it destroys all three silently (the expense survives with a dangling
-- source_id, still summed into `spent`, and unbooking can never find it again
-- — 00061 has no FK by design). So state-carrying rows are DEMOTED to manual
-- instead: auto = false takes them out of the derived set for good, they stop
-- being re-derived, and they render in the existing residual "Other bookings"
-- list where the traveler and the agent can edit or remove them. Demote rather
-- than merely skip: DeleteBookingTodoNonAuto refuses auto rows, so a skipped
-- survivor would be an undeletable zombie.
--
-- A saved shortlist (00065) is the fourth kind of traveler state, and the most
-- expensive to lose: booking_options CASCADEs off this row, so a delete here
-- silently destroys hand-collected research. Dropping a city from the itinerary
-- must not throw away the three Airbnbs someone compared for it.
UPDATE booking_todos b
SET auto = false
WHERE b.trip_id = $1 AND b.auto = true AND b.todo_key <> ALL(@keys::text[])
  AND (b.booked OR b.mode IS NOT NULL
       OR EXISTS (SELECT 1 FROM booking_options o WHERE o.booking_todo_id = b.id)
       OR EXISTS (
        SELECT 1 FROM trip_expenses e
        WHERE e.trip_id = b.trip_id
          AND e.source_kind = 'booking_todo' AND e.source_id = b.id));

-- name: DeleteStaleAutoBookingTodos :execrows
-- The rest of the prune: stale rows nobody has touched. Runs AFTER
-- DemoteStaleAutoBookingTodos, whose survivors are auto = false by then and so
-- fall outside this statement.
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

-- name: GetBookingTodo :one
-- Single leg, scoped to its trip so a foreign id can never be read or attached
-- to. Added for the booking-options paths (00065), which must confirm the leg
-- a candidate is being hung off actually belongs to this trip.
SELECT * FROM booking_todos WHERE id = $1 AND trip_id = $2;

-- name: GetBookingTodoDeleteState :one
-- Pre-delete read for the agent's remove_booking_todo guard — the second delete
-- path, the one DemoteStaleAutoBookingTodos' policy does not cover (the demote
-- preserves a state-carrying row as auto = false; this statement is what stops
-- the agent then hard-deleting that survivor). Same state-carrying predicate as
-- the demote MINUS mode: booked, a saved shortlist (booking_options CASCADEs
-- off this row), or a linked trip_expenses row (00061's untyped pair — the
-- expense survives a delete, dangling and still summed into `spent`). A mode
-- override alone is cheap to re-make, so it is deliberately not guarded.
-- Scoped auto = false so an auto row reads as "no such row" and the caller
-- answers with the same refusal DeleteBookingTodoNonAuto gives today.
SELECT b.title, b.booked,
       (SELECT count(*)::int FROM booking_options o WHERE o.booking_todo_id = b.id) AS option_count,
       EXISTS (SELECT 1 FROM trip_expenses e
               WHERE e.trip_id = b.trip_id
                 AND e.source_kind = 'booking_todo' AND e.source_id = b.id) AS has_expense
FROM booking_todos b
WHERE b.id = $1 AND b.trip_id = $2 AND b.auto = false;
