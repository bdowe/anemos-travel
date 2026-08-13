-- +goose Up
-- Links a budget expense to the booking row that spawned it (budget
-- autopopulate, specs/budget-v2). No FK on purpose: booking rows are
-- deletable/re-synced, and a dangling link simply degrades the expense to a
-- plain line item (the local_source snapshot pattern).
--
-- This also gives 00042's reserved `auto` column its contract:
--   auto = true  => system-managed mirror of the source row's booked state —
--                   created on the booked flip, DELETED on unbook.
--   auto = false => traveler-owned. Any user edit of category/label/amount
--                   flips auto false (manual takeover; server rule in
--                   budget_handler.go) and unbooking then leaves the row.
-- The partial unique index makes no-double-create a DB invariant (re-booking
-- upserts by source instead of inserting a duplicate).
ALTER TABLE trip_expenses ADD COLUMN source_kind text; -- booking_todo | accommodation | segment
ALTER TABLE trip_expenses ADD COLUMN source_id uuid;
ALTER TABLE trip_expenses ADD CONSTRAINT trip_expenses_source_pair
    CHECK ((source_kind IS NULL) = (source_id IS NULL));
CREATE UNIQUE INDEX idx_trip_expenses_source
    ON trip_expenses (trip_id, source_kind, source_id)
    WHERE source_kind IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS idx_trip_expenses_source;
ALTER TABLE trip_expenses DROP CONSTRAINT IF EXISTS trip_expenses_source_pair;
ALTER TABLE trip_expenses DROP COLUMN IF EXISTS source_id;
ALTER TABLE trip_expenses DROP COLUMN IF EXISTS source_kind;
