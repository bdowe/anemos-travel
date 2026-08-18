-- +goose Up
-- Frees 00070's leg_key for general city tagging (spend-per-city breakdown).
--
-- 00070 gave leg_key ONE job: be the identity of a city's daily food & drink
-- plan, so a double tap returns the row that exists instead of filing a
-- second one. That job is enforced by a partial UNIQUE index, and the index
-- is why the column could never also mean "this line happened in Rome": the
-- second Rome food line the traveler types would collide with the plan.
--
-- So the JOB moves out of the column and into its own boolean. leg_plan =
-- true means "this row IS the city's per-day plan slot for its category" —
-- the thing daily_spend_section.dart finds itself by, and the thing the
-- unique index guards. leg_key keeps only its plain meaning: the city leg
-- this money belongs to, RenderLeg.Key from computeTripLegs ("Rome",
-- "Rome#2"), still a SNAPSHOT with no FK — drop the city and the line
-- degrades to an untagged expense and lands in "Rest of trip", exactly as
-- 00070 promised.
--
-- Two facts, two columns, one representation each (docs/zen.md). The
-- alternative — inferring "is this the plan slot?" from category = 'food' —
-- is a convention someone must remember, and 00070's own comment already
-- anticipated a city carrying more than one kind of per-day plan.
ALTER TABLE trip_expenses ADD COLUMN leg_plan boolean NOT NULL DEFAULT false;

-- Backfill: the daily-spend card is, before this migration, the ONLY writer
-- of leg_key (POST /budget/expenses with leg_key), so every leg-keyed row
-- that exists is a plan slot. An id-preserving UPDATE, the 00064 rule.
UPDATE trip_expenses SET leg_plan = true WHERE leg_key IS NOT NULL;

-- A plan slot always names its city, and is never a booking mirror. Both
-- were true by construction before; now that leg_key has other writers they
-- have to be stated, or "leg_plan" becomes another thing held up by
-- convention.
ALTER TABLE trip_expenses ADD CONSTRAINT trip_expenses_leg_plan_needs_leg
    CHECK (NOT leg_plan OR leg_key IS NOT NULL);
ALTER TABLE trip_expenses ADD CONSTRAINT trip_expenses_leg_plan_not_linked
    CHECK (NOT leg_plan OR source_kind IS NULL);

-- The invariant narrows to the rows it was written for. One plan slot per
-- city per category stays a DB invariant (a double tap still can only ever
-- return the row that exists); ordinary tagged lines are unconstrained, so a
-- city can carry twenty dinners. A useful side effect: a PATCH that tags a
-- line can no longer raise 23505, because the index does not cover it. (A
-- category PATCH on a plan row can still, in principle, collide with this
-- index — pre-existing since 00070, surfaces as the handler's blanket 404,
-- and is LESS reachable than before; noted, not fixed here.)
DROP INDEX IF EXISTS idx_trip_expenses_leg;
CREATE UNIQUE INDEX idx_trip_expenses_leg
    ON trip_expenses (trip_id, leg_key, category)
    WHERE leg_key IS NOT NULL AND leg_plan;

-- What this migration does NOT change: leg_key is still not part of the
-- `auto` contract (00061). A stay's leg is stamped server-side at create as
-- a convenience and never re-stamped over a traveler's later choice;
-- unbooking still deletes/un-pays by the source link and never reads
-- leg_key. WHERE THE "a plan row's city is fixed" RULE LIVES:
-- patchExpenseHandler (budget_handler.go), which refuses a leg_key change on
-- a leg_plan row — not expressible as a CHECK (no OLD/NEW), and a trigger
-- for one guarded PATCH would hide the rule from the only file that can
-- explain it.

-- +goose Down
DROP INDEX IF EXISTS idx_trip_expenses_leg;
-- Restore 00070's world exactly: only plan rows carry a leg_key. Ordinary
-- tags must be cleared BEFORE the wide index returns — two tagged dinners in
-- the same city would otherwise make the CREATE itself fail. Lossy of the
-- tags, by design: they are a 00072 concept. Production only runs goose.Up
-- (db.go); Down is a dev affordance.
UPDATE trip_expenses SET leg_key = NULL WHERE leg_key IS NOT NULL AND NOT leg_plan;
CREATE UNIQUE INDEX idx_trip_expenses_leg
    ON trip_expenses (trip_id, leg_key, category)
    WHERE leg_key IS NOT NULL;
ALTER TABLE trip_expenses DROP CONSTRAINT IF EXISTS trip_expenses_leg_plan_not_linked;
ALTER TABLE trip_expenses DROP CONSTRAINT IF EXISTS trip_expenses_leg_plan_needs_leg;
ALTER TABLE trip_expenses DROP COLUMN IF EXISTS leg_plan;
