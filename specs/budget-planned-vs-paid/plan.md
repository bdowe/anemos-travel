# Plan: Planned vs paid expenses

> **HOW.** See `CLAUDE.md` for repo conventions; `docs/zen.md` governs the data
> model decisions recorded here.

## Technical Approach

`trip_expenses` gains two nullable columns — `planned_amount` (what the traveler
meant to spend) and `actual_amount` (what it cost) — with a CHECK that at least
one is present. **"Paid" is not a column**: it is `actual_amount IS NOT NULL`,
behind one Go predicate `expensePurchased()`. That mirrors how 00065 models
`chosen` (`promoted_* IS NOT NULL` → `optionChosen`) and follows its stated
doctrine — 00065 refused a `kind` column because "storing it twice is a live
drift vector", and a `status` column here would be a pure function of that same
nullness.

**Why two amounts and not a status an expense leaves.** At the end of a trip
everything is bought. If "planned" were a state a row exits on purchase, the
planned total would collapse to zero and the one comparison this feature exists
for would read "0 vs 3,400". The plan must survive the purchase, so it is its
own column — and there is deliberately **no API that clears it**.

**Why both columns are genuinely nullable.** `planned_amount = 0` (a free
walking tour budgeted at zero) must stay distinguishable from "never planned",
so a 0 sentinel is out. And back-filling `planned := actual` for an unplanned
purchase would *hide* unplanned spend — plan 3 legs at 500, buy them for 1600,
add a 200 souvenir you never planned: the honest answer is "planned 1500, spent
1800", not "planned 1700, spent 1800".

**`amount` is kept, not renamed**, and becomes derived — `COALESCE(actual,
planned)`, maintained by a trigger. sqlc expands `SELECT *` / `RETURNING *` into
explicit column lists at codegen (`store/trip_budgets.sql.go`), so *adding*
columns is invisible to an older binary, but a rename 42703s every pre-00067
image — and `query/trips.sql`'s `sum(e.amount)` lives inside
`ListLatestTripsByOwner`, so that would break the **trips list, the home
screen**, on exactly the rollback path `ci.yml`'s `workflow_dispatch` exists for.
A trigger rather than a `GENERATED` column because a generated column cannot be
INSERTed into, and a rolled-back image writes `amount` directly. Precedent:
`set_updated_at` on this same table. Writing `amount` by hand raises loudly
rather than being silently recomputed over (docs/zen.md: a discarded write is
how a wrong mental model survives unlimited "successful" calls).

**Backfill:** `UPDATE trip_expenses SET actual_amount = amount`. Every row that
exists today is a recorded purchase — the client calls the total "Total spent"
and `buildBudgetResponse` names it `spent`. An id-preserving UPDATE, so source
links, `auto` flags and positions survive by construction (the 00064 rule).
Decided with Brian: nothing on any screen moves on the day this ships, and any
row that was really an estimate is one tap from being re-tagged.

**Clearing a value gets a verb pair, not a tri-state decoder.**
`POST|DELETE /trips/{id}/budget/expenses/{expenseId}/purchase`, mirroring
`booking-options/{optionId}/choose`. Only one field is ever cleared, so a
presence-aware JSON protocol (an idiom this codebase has zero instances of)
would be a new mechanism for a one-off; worse, a `null`-means-clear convention
is unfalsifiable by inspection — an old client that serializes absent fields as
`null` would silently un-pay everything it touched. A verb cannot fire by
accident.

## Go API Changes

`src/packages/api/`:

- **Migration:** `migrations/00067_expense_planned_actual.sql` — two columns,
  backfill, three CHECKs, `set_expense_amount()` + `trg_trip_expenses_amount`.
  (00058 stays burned; number re-derived with `ls migrations | tail -1`.)
- **Queries** (`query/trip_budgets.sql`, then `make api-sqlc`): `CreateExpense`
  drops `amount` and takes both new columns; `UpdateExpense` gains
  `planned_amount` (plain `COALESCE` narg — overwritable, never clearable, the
  invariant expressed as the absence of a mechanism) and a `legacy_amount` CASE
  that writes back to whichever column the wire's `amount` was read from; new
  `GetExpense`, `PurchaseExpense`, `UnpurchaseExpense`,
  `ClearExpenseActualAmount`.
- **Query** (`query/trips.sql`): the list lateral becomes
  `sum(e.actual_amount)`. Mandatory — otherwise the trips-list pill and the
  Budget tab report two different "spent" numbers with no error anywhere. No
  `budget_planned` wire field: nothing renders it.
- **Handlers** (`budget_handler.go`): `sumExpenses` (the ONE derivation, shared
  with the print packet), `expensePurchased`, extended request/response structs,
  validation, `linkedExpense` params struct, `purchaseExpenseHandler` /
  `unpurchaseExpenseHandler`.
- **Routes** (`main.go`): the two `/purchase` routes beside the budget block.
- **`booking_option_choose.go`:** choose passes `ActualAmount`; unchoose
  un-pays instead of deleting when the row carries a plan (`auto` stays true —
  it is still the leg's mirror, and re-booking re-pays it).
- **`print_view_handler.go`:** `buildPrintBudget` consumes `sumExpenses`;
  `printBudgetRow`/`printBudget`/`printLabels` gain Planned; the table gains a
  column.
- **`trip_review.go`:** `checkBudget` gains a second, `info`-level finding when
  the projection exceeds the target and spend still fits. Category stays
  `"budget"` and the `raise_budget` fix is reused, so no client icon map moves.
- **`i18n.go`:** `print.planned`, `review.planOverBudget` — **en and es both**.

`review_handler.go` and `plan_tools_extra.go` need no edits: they consume
`buildBudgetResponse` and inherit the new totals. That is the payoff of one
derivation — and it is how the chat agent becomes plan-aware with zero
prompt-cache risk (`plan_tool_registry.go` is untouched).

The `auto` rule, extended (00061's contract, split by ownership): the system
owns `category`, `label` and `actual_amount` on a linked row; the traveler owns
`planned_amount` on **every** row. So a `planned_amount`-only PATCH leaves
`auto` alone (flipping it would break the mirror and strand a stale purchase),
while the purchase verbs set `auto = false` — naming, or denying, what
something cost has always been a takeover.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models:** `models/expense.dart` (+`plannedAmount`, `actualAmount`,
  `purchased`; `amount` stays non-null), `models/budget.dart` (+`planned`,
  `projected`, `planVariance`, all nullable so an old server renders today's
  tab) → `make flutter-build-models`.
- **Service:** `services/budget_api_service.dart` — `addExpense(..., bool
  planned = false)` (default = today's meaning, so the trip-detail booked-flip
  call site keeps both compiling and its semantics), `purchaseExpense`,
  `unpurchaseExpense`.
- **Widget:** `widgets/budget_amounts.dart` (new, pure helpers + the state
  glyph and amount cell — precedent `budget_categories.dart`) and
  `widgets/budget_section.dart` (summary, rows, group markers, mark-paid /
  un-pay, edit dialog, sticky mode control on its own line so the add row's
  horizontal composition — and its 136px no-ellipsis regression test — is
  untouched).
  *[Later: the add row's OTHER hint was truncating to "Add a…" on every phone,
  which no test covered. It now measures both hints and stacks onto two lines
  when one line can't seat them, so the 136 is gone and the row's shape is
  derived rather than assumed. Keeping this control on its own line was the
  right call and is now a stronger one — see `_buildModeControl`.]*
- **Provider:** `providers/budget_provider.dart` — the planned/paid mode joins
  `ExpenseDraft` (PR #435), not widget `State`: it is a *choice*, like category,
  and must survive the remount that opening the chat panel causes.
- **l10n:** `app_en.arb` + `app_es.arb`, prefix **`budgetPlan`**; regenerate
  `app_localizations*.dart` **last**.

`lib/screens/trip_detail_screen.dart` is **not** touched. That is a designed
property: if this feature ever needs the god screen, the design is wrong.

## Contract Parity  ← anti-drift gate

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| `amount` (expense) | `float64` | `double` | no | ☐ |
| `planned_amount` (expense) | `*float64` | `double?` | yes | ☐ |
| `actual_amount` (expense) | `*float64` | `double?` | yes | ☐ |
| `purchased` (expense) | `bool` | `bool` | no | ☐ |
| `spent` (budget) | `float64` | `double` | no | ☐ |
| `remaining` (budget) | `*float64` | `double?` | yes | ☐ |
| `planned` (budget) | `float64` | `double?` | no / tolerant | ☐ |
| `projected` (budget) | `float64` | `double?` | no / tolerant | ☐ |
| `plan_variance` (budget) | `*float64` | `double?` | yes | ☐ |

The three budget totals are non-pointer on the Go side (a total is always a
number) but **nullable in Dart on purpose**: a client that outruns the server,
or a stale bundle against a rolled-back API, must render today's tab rather
than throw. `null` means "unknown", never `0`.

## Cross-cutting

- **Env vars:** none.
- **Gateway:** the two new paths sit under `/api/v1/`; no proxy config.

## Verification

See `tasks.md`.
