# Tasks: Planned vs paid expenses

> Dependency-ordered. `[P]` = can run in parallel with its siblings.
> Single lane (`budget-planned-vs-paid`), one PR. Migration **00067** reserved.

## API (Go)

- [ ] `migrations/00067_expense_planned_actual.sql` — two columns, backfill,
      three CHECKs, `set_expense_amount()` + trigger
- [ ] `query/trip_budgets.sql` — `CreateExpense`, `UpdateExpense`, `GetExpense`,
      `PurchaseExpense`, `UnpurchaseExpense`, `ClearExpenseActualAmount`
- [ ] `query/trips.sql` — list lateral sums `actual_amount`
- [ ] `make api-sqlc` (never hand-edit `store/`)
- [ ] `budget_handler.go` — `sumExpenses`, `expensePurchased`, response/request
      structs, validation, `linkedExpense`, the two purchase handlers
- [ ] Register the two `/purchase` routes in `main.go`
- [ ] `booking_option_choose.go` — choose writes `ActualAmount`; unchoose keeps
      a plan instead of deleting
- [ ] `print_view_handler.go` + `i18n.go` (`print.planned`) — Planned column
- [ ] `trip_review.go` + `i18n.go` (`review.planOverBudget`) — projection finding

## Models & codegen (Flutter)

- [ ] `models/expense.dart`, `models/budget.dart`
- [ ] `make flutter-build-models`
- [ ] Complete the Contract Parity table in `plan.md` (every row ✓)

## UI (Flutter) — **after PR #435 (`budget-draft`) merges**

- [ ] [P] `services/budget_api_service.dart` — `planned` flag + the two verbs
- [ ] [P] `widgets/budget_amounts.dart` (new) — pure helpers, glyph, amount cell
- [ ] `providers/budget_provider.dart` — planned/paid joins `ExpenseDraft`
- [ ] `widgets/budget_section.dart` — summary, rows, group markers, mark-paid,
      un-pay + Undo, edit dialog, sticky mode control
- [ ] `app_en.arb` + `app_es.arb` (prefix `budgetPlan`) → `make flutter-gen-l10n`
      **last**

## Verification

- [ ] `make api-fmt && make api-vet` clean; `make test-db && make api-test-go`
- [ ] `make flutter-analyze` clean; `make flutter-test`
- [ ] Migration up **and** down against a seeded DB; `amount` still holds
      `COALESCE(actual, planned)` after the down
- [ ] Manual end-to-end via the lane gateway: plan three expenses → mark one
      paid at a different price → un-pay → Undo → mark a booking booked →
      `/trips/{id}/print`
- [ ] A trip whose expenses are all paid reports identical numbers to before
      (the backfill's promise): tab headline, trips-list pill, print packet,
      health

## Lanes

Single lane; no fan-out.

| Lane | Branch | Migration # | Registry tail? | ARB key prefix | trip_detail? | Depends on |
|------|--------|-------------|----------------|----------------|--------------|------------|
| — | `budget-planned-vs-paid` | 00067 | no | `budgetPlan` | **no** | PR #435 (UI half only) |

**Conflict manifest (existing files):** `query/trip_budgets.sql`,
`query/trips.sql`, `store/**` (regen), `budget_handler.go`, `main.go`,
`booking_option_choose.go`, `print_view_handler.go`, `trip_review.go`,
`i18n.go`, `budget_integration_test.go`, `booking_option_integration_test.go`,
`print_view_test.go`, `trip_review_test.go`, `trip_list_enrichment_test.go`;
`models/expense.dart`, `models/budget.dart`, `services/budget_api_service.dart`,
`providers/budget_provider.dart`, `widgets/budget_section.dart`,
`test/budget_section_test.dart`, both `.arb`s.

**Not claimed:** `lib/screens/trip_detail_screen.dart`, `plan_tool_registry.go`,
`widgets/booked_expense_prompt.dart`.
