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

-- name: CreateExpense :one
-- auto/source_kind/source_id: the booking-autopopulate link (00061). The
-- handler sets auto=true iff a source link is present — never the client.
INSERT INTO trip_expenses (trip_id, category, label, amount, position, auto, source_kind, source_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
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
UPDATE trip_expenses
SET category = COALESCE(sqlc.narg('category'), category),
    label    = COALESCE(sqlc.narg('label'), label),
    amount   = COALESCE(sqlc.narg('amount'), amount),
    position = COALESCE(sqlc.narg('position'), position),
    auto     = COALESCE(sqlc.narg('auto'), auto)
WHERE id = sqlc.arg('id') AND trip_id = sqlc.arg('trip_id')
RETURNING *;

-- name: DeleteExpense :execrows
DELETE FROM trip_expenses WHERE id = $1 AND trip_id = $2;
