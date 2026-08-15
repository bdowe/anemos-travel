-- name: GetBudgetByTrip :one
SELECT * FROM trip_budgets WHERE trip_id = $1;

-- name: UpsertBudget :one
-- One budget per trip: insert, or overwrite the target/currency of the existing
-- row (trip_id is UNIQUE). updated_at is bumped by the set_updated_at trigger.
INSERT INTO trip_budgets (trip_id, target_amount, currency)
VALUES ($1, $2, $3)
ON CONFLICT (trip_id) DO UPDATE
SET target_amount = EXCLUDED.target_amount,
    currency      = EXCLUDED.currency
RETURNING *;

-- name: ListExpensesByTrip :many
SELECT * FROM trip_expenses
WHERE trip_id = $1
ORDER BY position ASC, created_at ASC;

-- name: GetExpense :one
SELECT * FROM trip_expenses WHERE id = $1 AND trip_id = $2;

-- name: CreateExpense :one
-- auto/source_kind/source_id: the booking-autopopulate link (00061). The
-- handler sets auto=true iff a source link is present — never the client.
-- `amount` is deliberately absent from the column list: set_expense_amount()
-- (00066) computes it as COALESCE(actual_amount, planned_amount). One
-- definition, in the database, on every write path.
INSERT INTO trip_expenses (trip_id, category, label, planned_amount, actual_amount, position, auto, source_kind, source_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetExpenseBySource :one
-- The upsert-by-source lookup: at most one row per booking link (partial
-- unique index idx_trip_expenses_source).
SELECT * FROM trip_expenses
WHERE trip_id = $1 AND source_kind = $2 AND source_id = $3;

-- name: UpdateExpense :one
-- Partial update (COALESCE sqlc.narg idiom, see query/trip_checklist_items.sql
-- UpdateChecklistItem). COALESCE means a field can be overwritten but not
-- cleared to NULL (auto IS NOT NULL, so narg('auto') skips it when nil —
-- the handler passes false on a user content edit: manual takeover).
--
-- Three things to know since 00066:
--
--  1. planned_amount uses the PLAIN idiom on purpose. COALESCE can overwrite
--     but never clear, and here that limitation IS the contract: a plan, once
--     stated, is history. The feature's central invariant, expressed as the
--     absence of a mechanism.
--  2. legacy_amount is the pre-00066 wire field, resolved to a column IN SQL so
--     the read-modify-write is atomic and lives in exactly one statement: it
--     writes back to whichever column the wire's `amount` was READ from
--     (actual on a paid row, planned otherwise), so an old bundle's edit dialog
--     round-trips the number the user was looking at instead of silently
--     re-classifying the line.
--  3. `amount` is never listed. The trigger recomputes it; writing it by hand
--     raises.
UPDATE trip_expenses
SET category = COALESCE(sqlc.narg('category'), category),
    label    = COALESCE(sqlc.narg('label'), label),
    planned_amount = CASE
        WHEN sqlc.narg('legacy_amount')::float8 IS NOT NULL AND actual_amount IS NULL
            THEN sqlc.narg('legacy_amount')::float8
        ELSE COALESCE(sqlc.narg('planned_amount'), planned_amount) END,
    actual_amount = CASE
        WHEN sqlc.narg('legacy_amount')::float8 IS NOT NULL AND actual_amount IS NOT NULL
            THEN sqlc.narg('legacy_amount')::float8
        ELSE COALESCE(sqlc.narg('actual_amount'), actual_amount) END,
    position = COALESCE(sqlc.narg('position'), position),
    auto     = COALESCE(sqlc.narg('auto'), auto)
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id')
RETURNING *;

-- name: PurchaseExpense :one
-- Records what a line ACTUALLY cost (00066). A NULL actual_amount arg means
-- "bought it at the planned amount". The WHERE clause refuses the one
-- combination that would leave a line with no money at all — no amount given
-- AND no plan to fall back on — so the handler answers 404/409 instead of
-- letting trip_expenses_amount_present 500.
--
-- auto = false unconditionally: a traveler naming what something cost is a
-- manual takeover, the same rule a content PATCH follows (00061). The
-- booked-flip path does NOT come through here — it uses upsertLinkedExpense,
-- which keeps auto true.
UPDATE trip_expenses
SET actual_amount = COALESCE(sqlc.narg('actual_amount')::float8, planned_amount),
    auto = false
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id')
  AND (sqlc.narg('actual_amount')::float8 IS NOT NULL OR planned_amount IS NOT NULL)
RETURNING *;

-- name: UnpurchaseExpense :one
-- "I haven't actually paid this." Clears the actual, keeps the plan. Returns no
-- row when the line has no plan — un-purchasing it would erase it entirely, and
-- deleting a line on the traveler's behalf is a guess; the handler 409s and
-- says to delete it instead.
--
-- auto = false: same takeover rule as PurchaseExpense. The SYSTEM's un-purchase
-- (unbook) is a different statement, ClearExpenseActualAmount, which keeps auto.
UPDATE trip_expenses
SET actual_amount = NULL, auto = false
WHERE id = $1 AND trip_id = $2 AND planned_amount IS NOT NULL
RETURNING *;

-- name: ClearExpenseActualAmount :execrows
-- The unbook half of the 00061 mirror contract, updated for 00066. An auto
-- expense with NO plan is a pure mirror of the purchase and is deleted with it
-- (unchanged). One that CARRIES A PLAN is un-purchased instead: the plan is the
-- traveler's and no booking-state change may destroy it. auto stays TRUE — the
-- row is still the leg's mirror, and re-booking re-purchases it through
-- upsertLinkedExpense's refresh path.
UPDATE trip_expenses SET actual_amount = NULL
WHERE id = $1 AND trip_id = $2 AND planned_amount IS NOT NULL;

-- name: DeleteExpense :execrows
DELETE FROM trip_expenses WHERE id = $1 AND trip_id = $2;
