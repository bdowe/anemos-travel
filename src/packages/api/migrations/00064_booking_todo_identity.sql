-- +goose Up
-- Derived transport rows stop taking their identity from a mutable endpoint
-- label, and a trip gains its own departure/return airports.
--
-- WHY. A derived leg's identity was the endpoint string itself
-- (`transport:<origin>>><dest>`, 00010). The origin token is whatever the
-- renderer had on hand — trips.origin (00062) or, failing that, the VIEWER's
-- saved home airport. So the label was both content and identity, and the
-- moment it changed the key changed: DeleteStaleAutoBookingTodos hard-deleted
-- the row and took the booked flag, the per-leg mode override (00055), the
-- manual position, and any linked expense's source (00061, no FK on purpose)
-- with it. 00062 froze trips.origin to dodge that, but left the wider door
-- open — traveler_preferences.home_airport is freely mutable (Settings, the
-- save_preferences agent tool, the background profile distiller), and the trip
-- screen re-derives and re-syncs on the very next open. Correcting a home
-- airport therefore dropped booked flags on every trip the traveler owned, and
-- a collaborator opening a shared trip did the same with THEIR airport.
-- docs/zen.md names this exactly: an invariant that only holds implicitly —
-- via rows that can be deleted — is not an invariant.
--
-- WHAT. The two home legs key on a reserved `@home` token whose POSITION in
-- the key carries the direction, and the endpoints move to columns:
--     home_outbound  transport:@home>>amsterdam   origin_label='ALB'
--     home_return    transport:rome>>@home        destination_label='EWR'
--     inter_city     transport:paris>>rome        (key unchanged)
--     stay           stay:paris                   (key unchanged)
-- Changing either airport is then a title/label update that
-- UpsertBookingTodosBatch already performs in place — booked/auto/mode are
-- deliberately outside its DO UPDATE set, so they survive. The two directions
-- stay distinct keys, which is what lets a trip fly out of ALB and home into
-- EWR. `@` rather than a bare `home`: namesAPlace (trip_next_step.go) accepts
-- the word "home" as a city and would leak it into traveler-facing copy, while
-- `@` cannot occur in an IATA code or a Places label, so one guard is total.
--
-- The canonical key is computed SERVER-side in syncBookingTodosHandler, never
-- trusted from the client. That is what makes a stale tab, an old cached
-- bundle, or a collaborator's device land on the SAME row instead of pruning
-- it.
--
-- Every backfill statement below is an id-preserving UPDATE — never
-- delete+insert — so booked, mode, position, created_at and every
-- trip_expenses.source_id link survive by construction.
ALTER TABLE booking_todos ADD COLUMN role              text; -- home_outbound | home_return | inter_city | stay
ALTER TABLE booking_todos ADD COLUMN origin_label      text; -- cased display label, e.g. "ALB"
ALTER TABLE booking_todos ADD COLUMN destination_label text; -- cased display label, e.g. "Amsterdam"

-- This trip's own flight endpoints. Two columns, not one, because a trip can
-- leave from ALB and come home into EWR. NULL never means "same as the other
-- one": the single writer (the agent's set_trip_origin tool) always writes
-- BOTH, copying the departure into return_airport when the traveler named only
-- one — a default nobody can see is what put an EWR leg on an Albany trip in
-- the first place. NULL means only "this trip never stated an airport", which
-- keeps the legacy fallback to trips.origin and then the saved home airport.
-- Distinct from trips.origin (00062), which stays free text: origin is where
-- they set out from IN THEIR OWN WORDS ("Lake George, NY") and resolves to no
-- coordinates; these are codes, so the map can pin them.
ALTER TABLE trips ADD COLUMN origin_airport text;
ALTER TABLE trips ADD COLUMN return_airport text;
ALTER TABLE trips ADD CONSTRAINT trips_origin_airport_iata
    CHECK (origin_airport IS NULL OR origin_airport ~ '^[A-Z]{3}$');
ALTER TABLE trips ADD CONSTRAINT trips_return_airport_iata
    CHECK (return_airport IS NULL OR return_airport ~ '^[A-Z]{3}$');
-- Written together or not at all (the trip_expenses_source_pair pattern, 00061).
ALTER TABLE trips ADD CONSTRAINT trips_endpoint_airport_pair
    CHECK ((origin_airport IS NULL) = (return_airport IS NULL));

-- 1. Stay rows. The title is the only carrier of the client's casing (see the
--    section comment above legEndpoints in trip_next_step.go), so it wins and
--    the key suffix is the fallback. regexp_replace returns its input unchanged
--    on no-match, which is what NULLIF(..., title) tests for.
UPDATE booking_todos SET
    role = 'stay',
    destination_label = COALESCE(
        NULLIF(regexp_replace(title, '^Stay in ', ''), title),
        substring(todo_key from 6))
WHERE kind = 'stay' AND todo_key LIKE 'stay:%';

-- 2. Transport endpoints, same title-then-key precedence. ' → ' is U+2192,
--    the separator _deriveTodos builds titles with.
UPDATE booking_todos SET
    origin_label = COALESCE(
        NULLIF(split_part(title, ' → ', 1), ''),
        split_part(substring(todo_key from 11), '>>', 1)),
    destination_label = COALESCE(
        NULLIF(split_part(title, ' → ', 2), ''),
        split_part(substring(todo_key from 11), '>>', 2))
WHERE kind = 'transport' AND todo_key LIKE 'transport:%>>%';

-- 3. Role + canonical key. The classifier is the rule stayCitySet already
--    states (a transport endpoint outside the trip's stay cities is a home
--    leg; an EMPTY stay set never reads as home), restricted to the first and
--    last transport row — which is _deriveTodos' construction order: outbound
--    first, return last. `substring(from 11)` strips the 10-char 'transport:'.
WITH stays AS (
    SELECT trip_id, lower(substring(todo_key from 6)) AS city
    FROM booking_todos
    WHERE auto AND todo_key LIKE 'stay:%'
), legs AS (
    SELECT b.id, b.trip_id,
           lower(split_part(substring(b.todo_key from 11), '>>', 1)) AS o,
           lower(split_part(substring(b.todo_key from 11), '>>', 2)) AS d,
           row_number() OVER (PARTITION BY b.trip_id ORDER BY b.position, b.created_at) AS rn,
           count(*)     OVER (PARTITION BY b.trip_id)                                   AS n,
           EXISTS (SELECT 1 FROM stays s WHERE s.trip_id = b.trip_id)                   AS has_stays
    FROM booking_todos b
    WHERE b.auto AND b.kind = 'transport' AND b.todo_key LIKE 'transport:%>>%'
), classified AS (
    SELECT l.*, CASE
        WHEN l.has_stays AND l.rn = 1
             AND NOT EXISTS (SELECT 1 FROM stays s WHERE s.trip_id = l.trip_id AND s.city = l.o)
            THEN 'home_outbound'
        WHEN l.has_stays AND l.rn = l.n
             AND NOT EXISTS (SELECT 1 FROM stays s WHERE s.trip_id = l.trip_id AND s.city = l.d)
            THEN 'home_return'
        ELSE 'inter_city'
    END AS role FROM legs l
), targets AS (
    SELECT c.id, c.trip_id, c.role, CASE c.role
        WHEN 'home_outbound' THEN 'transport:@home>>' || c.d
        WHEN 'home_return'   THEN 'transport:' || c.o || '>>@home'
        ELSE NULL
    END AS new_key FROM classified c
)
UPDATE booking_todos b
SET todo_key = COALESCE(t.new_key, b.todo_key),
    -- A home role is only legal once the key actually became canonical (the
    -- CHECKs below enforce that pairing). When the rename is blocked by a
    -- collision the row keeps its literal key and reads as inter_city — the
    -- runtime canonicalizer has the identical fallback, so the two agree.
    role = CASE
        WHEN t.new_key IS NULL THEN t.role
        WHEN EXISTS (SELECT 1 FROM booking_todos x
                     WHERE x.trip_id = t.trip_id AND x.todo_key = t.new_key AND x.id <> t.id)
            THEN 'inter_city'
        ELSE t.role
    END
FROM targets t
WHERE b.id = t.id
  -- Never violate idx_booking_todos_trip_key: a collision on a pathological
  -- itinerary is a no-op rename, not an aborted migration.
  AND (t.new_key IS NULL OR NOT EXISTS (
        SELECT 1 FROM booking_todos x
        WHERE x.trip_id = t.trip_id AND x.todo_key = t.new_key AND x.id <> t.id));

-- 4. Only now, with every home row canonical, can the pairing bind. A wrong
--    canonicalization then fails loudly at write time instead of producing a
--    plausible-looking wrong row.
ALTER TABLE booking_todos ADD CONSTRAINT booking_todos_home_outbound_key
    CHECK (role IS DISTINCT FROM 'home_outbound' OR todo_key LIKE 'transport:@home>>%');
ALTER TABLE booking_todos ADD CONSTRAINT booking_todos_home_return_key
    CHECK (role IS DISTINCT FROM 'home_return' OR todo_key LIKE '%>>@home');

-- +goose Down
-- Rebuilds literal keys from the labels. Note this reconstructs the CURRENT
-- endpoints, not the historical ones: if a trip's departure airport changed
-- while the new code was live, the restored key names the new airport. That is
-- what the old client would derive anyway, so it is correct — but it is worth
-- saying out loud rather than leaving to be discovered.
ALTER TABLE booking_todos DROP CONSTRAINT IF EXISTS booking_todos_home_return_key;
ALTER TABLE booking_todos DROP CONSTRAINT IF EXISTS booking_todos_home_outbound_key;
UPDATE booking_todos b
SET todo_key = 'transport:' || lower(b.origin_label) || '>>' || lower(b.destination_label)
WHERE b.role IN ('home_outbound', 'home_return')
  AND b.origin_label IS NOT NULL AND b.destination_label IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM booking_todos x
        WHERE x.trip_id = b.trip_id
          AND x.todo_key = 'transport:' || lower(b.origin_label) || '>>' || lower(b.destination_label)
          AND x.id <> b.id);
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_endpoint_airport_pair;
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_return_airport_iata;
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_origin_airport_iata;
ALTER TABLE trips DROP COLUMN IF EXISTS return_airport;
ALTER TABLE trips DROP COLUMN IF EXISTS origin_airport;
ALTER TABLE booking_todos DROP COLUMN IF EXISTS destination_label;
ALTER TABLE booking_todos DROP COLUMN IF EXISTS origin_label;
ALTER TABLE booking_todos DROP COLUMN IF EXISTS role;
