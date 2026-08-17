-- name: CreateTrip :one
-- origin / origin_airport / return_airport are set here and by SetTripEndpoints
-- (the agent's set_trip_origin tool) — and nowhere else. They stay out of
-- UpdateTrip's COALESCE set so PATCH cannot move them: a departure airport is
-- not a field to be poked at, it is a change that has to travel with the trip's
-- derived legs (see 00064 and TestPatchTripCannotSetOrigin).
INSERT INTO trips (user_id, title, chat_id, summary, summary_source, travel_mode, origin, origin_airport, return_airport, updated_by)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $1)
RETURNING *;

-- name: SetTripEndpoints :one
-- The ONE writer of a saved trip's departure/return endpoints. Deliberately
-- unscoped by user_id, like SetTripDates: the caller authorizes (owner or
-- editor collaborator, via resolveDateShiftTrip).
--
-- The two airports are written TOGETHER, always. NULL never means "same as the
-- other direction" — a default nobody can see is what put an EWR leg on a trip
-- leaving from Albany — it means only that this trip states no airport, and the
-- legs fall back to trips.origin and then the owner's saved home airport.
-- CHECK trips_endpoint_airport_pair (00064) makes that a DB invariant.
UPDATE trips
SET origin = sqlc.narg('origin'),
    origin_airport = sqlc.narg('origin_airport'),
    return_airport = sqlc.narg('return_airport')
WHERE id = sqlc.arg('id')
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
-- (trip health, the next-step ladder) stay off the list. The shared EXISTS
-- is the HasActiveCollaborators predicate — keep the two in sync.
--
-- Lateral semantics (specs/trips-page-insights):
--   c  — ONE itinerary scan emits both cities and city_pins, so pins are a
--        subset of cities in the same first-appearance order structurally.
--        A hub's pin is its first item by position with non-(0,0) coords —
--        itinerary_items.latitude/longitude are NOT NULL with (0,0) as the
--        no-location sentinel (the computeTripLegs rule); a hub with only
--        sentinel items appears in cities but never in city_pins.
--   bt — booking-todo progress + next_transport_depart, the earliest
--        UNBOOKED future TRANSPORT depart date (the booking-urgency nudge).
--   st — CONFIRMED stays only (auto = false AND NOT dismissed, the
--        ListConfirmedAccommodationsByTrip rule — drafts churn with the
--        itinerary sync and would make the count flap).
--   pk — packing-checklist progress.
--   tb/ex — budget target+currency and PAID expense sum, joined SEPARATELY so a
--        trip with expenses but no budget row still reports spent; currency
--        defaults to USD, matching buildBudgetResponse (single-currency by
--        design — no FX).
SELECT latest.id, latest.user_id, latest.created_at, latest.updated_at,
       latest.title, latest.start_date, latest.end_date,
       latest.chat_id, latest.summary, latest.version_count,
       COALESCE(c.cities, ARRAY[]::text[])::text[] AS cities,
       COALESCE(c.city_pins, '[]'::jsonb) AS city_pins,
       COALESCE(ic.item_count, 0)::int AS item_count,
       COALESCE(bt.total, 0)::int AS booking_total,
       COALESCE(bt.booked, 0)::int AS booking_booked,
       bt.next_transport_depart::date AS next_transport_depart,
       COALESCE(st.total, 0)::int AS stay_total,
       COALESCE(st.booked, 0)::int AS stay_booked,
       COALESCE(pk.total, 0)::int AS packing_total,
       COALESCE(pk.done, 0)::int AS packing_done,
       tb.target_amount AS budget_target,
       COALESCE(ex.spent, 0)::float8 AS budget_spent,
       COALESCE(tb.currency, 'USD')::text AS budget_currency,
       EXISTS (
         SELECT 1 FROM trip_collaborators tc
         WHERE tc.owner_id = latest.user_id AND tc.chat_id = latest.chat_id
           AND tc.revoked_at IS NULL
       )::bool AS shared
FROM (
  SELECT DISTINCT ON (COALESCE(chat_id, id::text))
         id, user_id, created_at, updated_at, title, start_date, end_date, chat_id, summary,
         count(*) OVER (PARTITION BY COALESCE(chat_id, id::text)) AS version_count
  FROM trips WHERE trips.user_id = $1
  ORDER BY COALESCE(chat_id, id::text), created_at DESC
) latest
LEFT JOIN LATERAL (
  SELECT array_agg(hub.city ORDER BY hub.first_pos) AS cities,
         jsonb_agg(jsonb_build_object('city', hub.city, 'lat', hub.lat, 'lng', hub.lng)
                   ORDER BY hub.first_pos)
           FILTER (WHERE hub.lat IS NOT NULL) AS city_pins
  FROM (
    SELECT COALESCE(NULLIF(ii.day_trip_from, ''), NULLIF(ii.city, '')) AS city,
           MIN(ii.position) AS first_pos,
           (array_agg(ii.latitude ORDER BY ii.position)
              FILTER (WHERE ii.latitude <> 0 OR ii.longitude <> 0))[1] AS lat,
           (array_agg(ii.longitude ORDER BY ii.position)
              FILTER (WHERE ii.latitude <> 0 OR ii.longitude <> 0))[1] AS lng
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
  SELECT count(*) AS total, count(*) FILTER (WHERE b.booked) AS booked,
         min(b.depart_date) FILTER (WHERE NOT b.booked AND b.kind = 'transport'
                                      AND b.depart_date >= CURRENT_DATE) AS next_transport_depart
  FROM booking_todos b WHERE b.trip_id = latest.id
) bt ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS total, count(*) FILTER (WHERE a.booked) AS booked
  FROM accommodations a
  WHERE a.trip_id = latest.id AND a.auto = false AND NOT a.dismissed
) st ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS total, count(*) FILTER (WHERE ck.checked) AS done
  FROM trip_checklist_items ck WHERE ck.trip_id = latest.id
) pk ON true
LEFT JOIN trip_budgets tb ON tb.trip_id = latest.id
LEFT JOIN LATERAL (
  -- actual_amount, NOT amount: since 00067 `amount` is
  -- COALESCE(actual, planned), so summing it here would quietly fold money the
  -- traveler has only PLANNED into a pill labelled "spent" — and the Budget tab
  -- would report a different number for the same trip, with no error anywhere.
  -- budget_spent means money actually spent, exactly as buildBudgetResponse's
  -- `spent` does. Pinned by TestListRowBudgetMatchesBudgetEndpoint.
  SELECT sum(e.actual_amount) AS spent FROM trip_expenses e WHERE e.trip_id = latest.id
) ex ON true
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

-- name: SetTripSummary :exec
-- The ONE writer of a saved trip's description after creation (00071,
-- specs/trip-description) — called by applyTripSummary for both the trip page's
-- PATCH and the chat's set_trip_description. Authorization happens in the
-- callers (editableTrip / resolveDateShiftTrip), same as SetTripDates, so editor
-- collaborators can write.
--
-- Plain narg rather than UpdateTrip's COALESCE, deliberately: COALESCE cannot
-- carry "write NULL", so a description could be set and replaced but never
-- CLEARED (the limitation PatchTripRequest.TravelMode's comment laments and
-- query/preferences.sql's clear_home_airport flag was written to escape). The two
-- columns move together — a description and whose words it is are one fact.
UPDATE trips SET summary = sqlc.narg('summary'), summary_source = sqlc.narg('summary_source')
WHERE id = sqlc.arg('id');

-- name: GetLatestTripSummaryByChat :one
-- The newest version's description in a chat lineage. persistTrip reads it to
-- carry the prose forward when a version save supplies none: every save INSERTs
-- a new row, so without this a re-save silently drops the description — reachable
-- today with no UPDATE statement existing anywhere.
SELECT summary, summary_source FROM trips
WHERE user_id = $1 AND chat_id = $2
ORDER BY created_at DESC
LIMIT 1;

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
