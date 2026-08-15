-- +goose Up
-- Planned vs paid (specs/budget-planned-vs-paid): an expense line carries TWO
-- numbers — what the traveler meant to spend, and what it actually cost.
--
-- WHY NOT A STATUS AN EXPENSE LEAVES. At the end of a trip everything is
-- bought. If "planned" were a state a row exits on purchase, the planned total
-- would collapse to zero and the one comparison this feature exists for — what
-- I meant to spend vs what I spent — would read "0 vs 3,400". The plan has to
-- survive the purchase, so it is its own column, written and then kept: there
-- is deliberately NO API that clears planned_amount (see PatchExpenseRequest).
--
-- WHY NO `status`/`purchased` COLUMN EITHER. paid <=> actual_amount IS NOT
-- NULL, the same shape 00065 uses for `chosen` (promoted_* IS NOT NULL, one
-- predicate, optionChosen). A status column would be a pure function of that
-- nullness, and two representations of one fact is precisely the drift 00065's
-- own "NO kind COLUMN" note refuses. The Go predicate is expensePurchased().
--
-- BOTH NULLABLE, DELIBERATELY. planned_amount must distinguish "planned zero"
-- (a free walking tour you budgeted at 0) from "never planned", so a 0 sentinel
-- is out. And back-filling planned := actual for an unplanned purchase would
-- HIDE unplanned spend: plan three legs at 500, buy them for 1600, add a 200
-- souvenir you never planned — the honest answer is "planned 1500, spent 1800",
-- not "planned 1700, spent 1800".
ALTER TABLE trip_expenses ADD COLUMN planned_amount double precision;
ALTER TABLE trip_expenses ADD COLUMN actual_amount  double precision;

-- Backfill. Every row that exists today is a RECORDED PURCHASE: the client
-- calls the total "Total spent" and buildBudgetResponse names it `spent`. The
-- money moves to actual_amount and no row gains a plan it never had. An
-- id-preserving UPDATE, never delete+insert (the 00064 rule), so source links,
-- auto flags and positions survive by construction.
UPDATE trip_expenses SET actual_amount = amount;

ALTER TABLE trip_expenses ADD CONSTRAINT trip_expenses_amount_present
    CHECK (planned_amount IS NOT NULL OR actual_amount IS NOT NULL);
ALTER TABLE trip_expenses ADD CONSTRAINT trip_expenses_planned_nonneg
    CHECK (planned_amount IS NULL OR planned_amount >= 0);
ALTER TABLE trip_expenses ADD CONSTRAINT trip_expenses_actual_nonneg
    CHECK (actual_amount IS NULL OR actual_amount >= 0);

-- `amount` STAYS, AND STOPS BEING WRITTEN BY HAND.
--
-- It is NOT renamed. sqlc expands SELECT */RETURNING * into explicit column
-- lists at codegen (see store/trip_budgets.sql.go), so ADDING columns is
-- invisible to an older binary — which is why 00061 was harmless — but a
-- RENAME is a different class: every pre-00066 API image would fail 42703 on
-- ListLatestTripsByOwner, i.e. the TRIPS LIST, the app's home screen, and on
-- all six budget routes. That is the rollback path ci.yml's workflow_dispatch
-- exists for, and it must stay read-safe.
--
-- Instead the column keeps its name and becomes the one headline figure for
-- this line: COALESCE(actual_amount, planned_amount). It is what the wire's
-- legacy `amount` serves (a cached Flutter bundle does
-- `(json['amount'] as num).toDouble()` and a null takes the whole budget list
-- down with it), and what a rolled-back image reads.
--
-- A TRIGGER, not hand-written SQL in two queries: a mirror maintained by
-- convention is not an invariant (docs/zen.md). A trigger, not a GENERATED
-- column: a generated column cannot be INSERTed into, and a rolled-back image
-- writes `amount` directly. Precedent: set_updated_at on this same table.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION set_expense_amount() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- A writer that predates 00066 sets only `amount`, and that number has
        -- always meant money spent. Adopt it as the purchase, so a rolled-back
        -- image can still CREATE expenses instead of tripping amount_present.
        IF NEW.planned_amount IS NULL AND NEW.actual_amount IS NULL THEN
            NEW.actual_amount := NEW.amount;
        END IF;
    ELSIF NEW.amount IS DISTINCT FROM OLD.amount
          AND NEW.planned_amount IS NOT DISTINCT FROM OLD.planned_amount
          AND NEW.actual_amount  IS NOT DISTINCT FROM OLD.actual_amount THEN
        -- Somebody hand-wrote the derived column. Refuse LOUDLY rather than
        -- recompute over the top of it: a silently discarded write is how a
        -- wrong mental model survives unlimited "successful" calls
        -- (docs/zen.md, the leg-dates arc). This is also the boundary that
        -- stops future Go code from re-introducing a second writer.
        RAISE EXCEPTION
          'trip_expenses.amount is derived from planned_amount/actual_amount (migration 00066) and cannot be written directly';
    END IF;
    NEW.amount := COALESCE(NEW.actual_amount, NEW.planned_amount);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

CREATE TRIGGER trg_trip_expenses_amount
    BEFORE INSERT OR UPDATE ON trip_expenses
    FOR EACH ROW EXECUTE FUNCTION set_expense_amount();

-- +goose Down
DROP TRIGGER IF EXISTS trg_trip_expenses_amount ON trip_expenses;
DROP FUNCTION IF EXISTS set_expense_amount();
ALTER TABLE trip_expenses DROP CONSTRAINT IF EXISTS trip_expenses_actual_nonneg;
ALTER TABLE trip_expenses DROP CONSTRAINT IF EXISTS trip_expenses_planned_nonneg;
ALTER TABLE trip_expenses DROP CONSTRAINT IF EXISTS trip_expenses_amount_present;
ALTER TABLE trip_expenses DROP COLUMN IF EXISTS actual_amount;
ALTER TABLE trip_expenses DROP COLUMN IF EXISTS planned_amount;
-- LOSSY, but only of structure, never of money: `amount` is left holding
-- COALESCE(actual, planned), so no row is emptied or orphaned. What is lost is
-- the plan-vs-purchase SPLIT — a line that was planned but not yet bought comes
-- back looking like a purchase, the exact inverse of the Up backfill.
-- Acceptable: production only ever runs goose.Up (db.go); Down is a dev
-- affordance, and refusing to drop would leave no way back at all.
