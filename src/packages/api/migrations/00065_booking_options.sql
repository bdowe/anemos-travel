-- +goose Up
-- A shortlist of candidate bookings per leg — the flights and stays a traveler
-- is deciding BETWEEN, before any of them is the answer.
--
-- WHY. Everything the trip screen persists today is a commitment: a booking
-- todo is "you still have to book this", an accommodation/segment is "this is
-- where you're staying / how you're travelling", an expense is money already
-- spent. The middle of planning — three Airbnbs open in tabs, two flights
-- being weighed — had nowhere to live, so it lived in the browser and the app
-- couldn't help with the one decision the traveler was actually making. Flight
-- offers in particular are never persisted anywhere (duffel_service.go: "Flight
-- offers are time-sensitive and never cached"), so a searched fare was gone the
-- moment the screen closed.
--
-- WHAT. One row per candidate, hanging off the leg it is a candidate for.
-- Choosing one PROMOTES it into the real record (accommodations/trip_segments)
-- and marks the leg booked; the losers stay until the traveler clears them.
--
-- IDENTITY. booking_todo_id, not a todo_key string. After 00064 a leg's row id
-- survives label and airport edits, and UpsertBookingTodosBatch is
-- ON CONFLICT (trip_id, todo_key) DO UPDATE, so ids are stable across every
-- trip open. Keying on the key instead would make every write post a
-- CLIENT-DERIVED key the server has to canonicalize — a second path computing
-- identity from a payload, which is the failure booking_todo_identity.go exists
-- to end — and would bake in displayBookingTodoKey, a spelling that dies at
-- specs/server-booking-todos. A uuid posted back is an opaque handle we issued.
--
-- NOT NULL + CASCADE, deliberately. A candidate with no leg has no renderer
-- (the UI draws options only underneath their leg's row) and no prune rule, so
-- nullable would create state nobody can see or delete. CASCADE means deleting
-- a leg deletes its shortlist — note deleteBookingTodoHandler calls
-- DeleteBookingTodo, which removes ANY row (DeleteBookingTodoNonAuto has no
-- callers), so the client confirms before that delete. The stale-key prune is
-- handled the other way: DemoteStaleAutoBookingTodos gains a fourth
-- state-carrying predicate for options, so a city removed from the itinerary
-- demotes its leg to auto=false and keeps the research instead of dropping it.
--
-- NO `kind` COLUMN. An option's kind is always its leg's kind. Storing it twice
-- is a live drift vector: UpdateBookingTodo permits kind edits on auto=false
-- rows and a demoted leg IS auto=false, so the two could disagree and `choose`
-- would promote a stay into a trip_segments row. Derived from the parent, in
-- one place.
CREATE TABLE booking_options (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id         uuid        NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    booking_todo_id uuid        NOT NULL REFERENCES booking_todos(id) ON DELETE CASCADE,

    title       text NOT NULL,             -- "Loft near Old Town" / "TAP Air Portugal"
    subtitle    text,                      -- "08:15 → 22:40 · 11h 20m · 1 stop"
    url         text,
    provider    text,                      -- airbnb|booking|kayak|google_flights|duffel|ferry|rome2rio
    notes       text,
    image_url   text,                      -- og:image from the link preview

    -- Money is numeric here, unlike accommodations.price_note's free text,
    -- because the Budget tab's "considering" projection has to add it up.
    -- double precision matches how money is carried everywhere else (00042).
    --
    -- Both or neither: a number with no currency is a number nobody can sum,
    -- and this app has no FX by design (00042: "NO cross-currency summing").
    -- Same doctrine as trip_expenses_source_pair (00061) and the paired
    -- endpoint airports (00064) — absence must never mean "assume the default".
    price       double precision,
    currency    text,
    CONSTRAINT booking_options_price_pair
        CHECK ((price IS NULL) = (currency IS NULL)),
    CONSTRAINT booking_options_currency_code
        CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
    CONSTRAINT booking_options_price_nonneg
        CHECK (price IS NULL OR price >= 0),

    start_date  date,   -- stay check-in  / transport depart
    end_date    date,   -- stay check-out / transport arrive
    -- An option may use DIFFERENT endpoints than its leg's labels: weighing a
    -- flight out of ALB against one out of EWR is exactly the kind of decision
    -- a shortlist is for. NULL falls back to the leg's labels at promotion.
    origin      text,
    destination text,
    -- Transport only. trip_segments.mode is NOT NULL, so promotion needs one;
    -- NULL here means "inherit the leg's mode", resolved by exactly one
    -- function (promotedSegmentMode) rather than re-derived per call site.
    mode        text,
    CONSTRAINT booking_options_mode
        CHECK (mode IS NULL OR mode IN ('flight','car','train','bus','ferry')),

    -- The winner link. TWO TYPED FKs rather than 00061's untyped
    -- (source_kind, source_id) pair, and the divergence is deliberate: 00061
    -- has no FK because booking rows are re-synced and deletable, so a dangling
    -- link degrades harmlessly. A promoted record is auto=false — outside sync
    -- ownership, deleted only by explicit user action — so the FK is safe, and
    -- ON DELETE SET NULL buys the un-choose for free: delete the stay you
    -- created and the option is simply a candidate again, with no
    -- reconciliation code and no way for "chosen" to point at nothing.
    --
    -- Deleting the record does NOT clear booked: that is traveler state (the
    -- checkbox is manually flippable) and no cascade has business flipping it.
    -- Pinned by TestDeletingPromotedRecordUnchoosesButLeavesBooked.
    promoted_accommodation_id uuid REFERENCES accommodations(id) ON DELETE SET NULL,
    promoted_segment_id       uuid REFERENCES trip_segments(id)  ON DELETE SET NULL,
    CONSTRAINT booking_options_one_promotion
        CHECK (num_nonnulls(promoted_accommodation_id, promoted_segment_id) <= 1),

    position    int         NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_booking_options_trip ON booking_options(trip_id, position, created_at);
CREATE INDEX idx_booking_options_todo ON booking_options(booking_todo_id);

-- One winner per leg, as a DB invariant rather than a handler convention (the
-- idx_trip_expenses_source precedent). The choose transaction clears the
-- previous winner first, so this is the backstop against a concurrent double
-- choose, not the mechanism.
CREATE UNIQUE INDEX idx_booking_options_winner ON booking_options(booking_todo_id)
    WHERE promoted_accommodation_id IS NOT NULL OR promoted_segment_id IS NOT NULL;

CREATE TRIGGER trg_booking_options_updated_at BEFORE UPDATE ON booking_options
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- +goose Down
DROP TABLE IF EXISTS booking_options;
