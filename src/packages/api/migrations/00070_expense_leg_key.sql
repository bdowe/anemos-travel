-- +goose Up
-- Binds a budget expense to ONE city leg of the trip (daily food & drink
-- guide, specs/daily-spend-guide). Without it "the food plan for Rome" has no
-- identity: the suggestion card cannot tell whether it is already in the plan,
-- and a second tap silently files a duplicate line. Matching on the generated
-- label instead would make the LABEL the key — the exact failure 00064 was
-- written to undo.
--
-- leg_key holds RenderLeg.Key from computeTripLegs ("Rome", "Rome#2"), the
-- same run-keyed spelling booking_todos already uses for a city's stay. Like
-- 00061's source link it is a SNAPSHOT, not a relationship: no FK, so renaming
-- or dropping the city just degrades the row to an ordinary food expense and
-- the card offers "Add to plan" again. Nothing cascades, nothing is lost.
--
-- What this column is NOT:
--   * not part of the `auto` contract. A leg-keyed row is the TRAVELER's plan,
--     never a system mirror of a booking, so auto stays false and no
--     booking-state change may touch it.
--   * not client-canonicalized. The handler refuses a key that is not one of
--     the trip's current legs, so a stale tab, an old cached bundle and a
--     collaborator all land on the same row (the 00064 rule).
--   * not patchable. POST /budget/expenses is the one writer; PATCH has no
--     mechanism to set or clear it.
--
-- The partial unique index makes one-plan-per-city-per-category a DB
-- invariant, so a double tap can only ever return the row that already exists.
-- Category is in the key because a city may later carry more than one kind of
-- per-day plan; food is simply the first.
ALTER TABLE trip_expenses ADD COLUMN leg_key text;
CREATE UNIQUE INDEX idx_trip_expenses_leg
    ON trip_expenses (trip_id, leg_key, category)
    WHERE leg_key IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS idx_trip_expenses_leg;
ALTER TABLE trip_expenses DROP COLUMN IF EXISTS leg_key;
