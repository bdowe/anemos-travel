# Plan: Daily food & drink budget, per city

> **HOW.** Translates `spec.md` into a file-level technical approach. See
> `../../CLAUDE.md` for repo conventions referenced below.

## Technical Approach

Three decisions carry the design.

**1. The estimate is a labelled model call, and that is written down.** Two
alternatives were checked and rejected on the data, not on preference. There is
no free, global, currency-denominated meal-price feed (Numbeo's is paid,
APIVerve is US-only indices, the marketplace resellers are per-request). And
this API talks to the **legacy** Google Places API, whose `price_level` is an
ordinal 0–4 — `hotel_search_service.go:285` already refused to map that onto
money for exactly this reason. So `estimateDailyFoodSpend` makes one forced-tool
`aiModelLight()` call, following `profile_distiller.go` exactly, and
`DailySpendGuide.Basis` carries `"estimate"` on the wire the way
`WeatherReport.Kind` carries forecast-vs-historical. A future real provider is a
new `basis` value, not a silent change of meaning.

**2. The multiplier is NIGHTS.** Two legs share their transition day (Rome ends
the morning Florence begins), so per-city *days* would bill that day twice and
the section could never reconcile with the trip's own length. Per-leg nights sum
exactly to trip nights. Nights come from `computeTripLegs` +
`nightsBetween` — the same derivation behind the city header chip — and a
parity test pins them together.

**3. A city plan needs an identity, so it gets a column.** Without one the card
cannot say whether a city is already planned and a second tap duplicates the
line. Matching the generated label would make the label *be* the key — the
failure 00064 was written to undo. Hence `trip_expenses.leg_key`.

The per-person amount and the nights ride the wire; the **party multiplication
happens client-side only**, because the client is the only place that knows the
party size. The server never sends a total.

## Go API Changes

`src/packages/api/`:

- **Migration `00070_expense_leg_key.sql`** — `trip_expenses.leg_key text` +
  partial unique index on `(trip_id, leg_key, category) WHERE leg_key IS NOT
  NULL`. ADD COLUMN only, so it is rollback-safe (sqlc expands `SELECT *` at
  codegen; see specs/budget-planned-vs-paid/plan.md for why a RENAME would not
  be). Snapshot semantics, no FK — 00061's pattern.
- **`query/trip_budgets.sql`** — `CreateExpense` gains the column;
  `GetExpenseByLegKey` is new; `UpdateExpense` deliberately never lists it.
  Regenerate with `make api-sqlc`.
- **`daily_spend_service.go`** (new) — `DailySpendGuide`/`DailySpendCity`,
  `resolveSpendTier` (the explicit ladder, modelled on `resolveBaggageTier`),
  `estimateDailyFoodSpend` (one call for all uncached cities), and a
  `ttlCache` at **30 days** — a city's food costs move on the scale of seasons,
  and the cache is the only real spend guard on the endpoint.
- **`daily_spend_handler.go`** (new) — `GET /trips/{id}/budget/daily-spend`
  behind `editableTrip`, plus `tripLegKeyExists`, the canonicalization boundary
  the expense POST calls.
- **`budget_handler.go`** — `AddExpenseRequest.LegKey`,
  `ExpenseResponse.LegKey`, the validation ladder, and a second upsert branch in
  `upsertLinkedExpense` (found ⇒ untouched, always). `PatchExpenseRequest` is
  untouched, deliberately.
- **Route** registered beside the other budget routes in `main.go`.
- **No new env var.** It reuses `ANTHROPIC_API_KEY`; absent, the endpoint
  degrades.

Convention reminders honoured: `recordAIResult(err)` once per SDK call site
(`ai_health.go`); `forcedToolThinking()` on a forced-tool call; degrade-never-error
on a provider failure (`hotel_search_service.go`).

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **`models/daily_spend.dart`** (+ `.g.dart` via `make flutter-build-models`);
  `models/expense.dart` gains `legKey`.
- **`services/budget_api_service.dart`** — `getDailySpend`, and `legKey` on
  `addExpense`.
- **`providers/budget_provider.dart`** — `dailySpendProvider`
  (`FutureProvider.family` keyed by `DailySpendQuery{tripId, tier}`,
  **best-effort**: any failure resolves to an empty guide, the
  `weatherByCityProvider` convention) and `dailySpendSettingsProvider`
  (session-local tier + travelers, the `expenseDraftProvider` lifetime).
- **`utils/daily_spend.dart`** — `dailySpendTotal`, the ONE multiplication,
  shared by the figure on the card and the amount the button posts.
- **`widgets/daily_spend_section.dart`** (new) — the section, mounted from
  `budget_section.dart` between `_buildTotals` and `_buildModeControl`.

**`trip_detail_screen.dart` is not touched.** Because the server returns city,
nights and rate, the section needs nothing from the god screen — which also
means this lane does not contend for it.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| `currency` | `string` | `String` | no | ✓ |
| `tier` | `string` | `String` | no | ✓ |
| `tier_source` | `string` | `String` | no | ✓ |
| `basis` | `string` | `String` | no | ✓ |
| `cities` | `[]DailySpendCity` | `List<DailySpendCity>` | no | ✓ |
| `unavailable_reason` | `string,omitempty` | `String?` | yes | ✓ |
| `leg_key` (city) | `string` | `String` | no | ✓ |
| `label` | `string` | `String` | no | ✓ |
| `nights` | `int` | `int` | no | ✓ |
| `daily_amount` | `float64` | `double` | no | ✓ |
| `includes` | `string` | `String` | no | ✓ |
| `leg_key` (expense) | `*string` | `String?` | yes | ✓ |

## Cross-cutting

- **Env vars:** none new.
- **Gateway:** the path is under `/api/v1/`, so no proxy config changes.
- **l10n:** `budgetDaily*` in `app_en.arb` + `app_es.arb` in lockstep; CI fails
  on a non-empty `l10n_untranslated.json`. Spanish keeps *Previsto* for
  "planned" (00067 owns it) and does not reuse it here.
- **Downstream, for free:** planned food raises `projected`, so `checkBudget`'s
  "plan over budget" info finding fires correctly; `buildPrintBudget` groups it
  under Food; the trips-list pill sums `actual_amount` only and is unaffected.

## Verification

- `make api-fmt && make api-vet`; `go test ./... -race` with `TEST_DATABASE_URL`.
- `make api-sqlc` after the query edits; `make api-migrate`.
- `make flutter-build-models`, `make flutter-gen-l10n`, `make flutter-analyze`
  (3 pre-existing infos in `models/route_response.dart` are not ours),
  `make flutter-test`.
- Manual end-to-end through the gateway on a dated multi-city trip: nights match
  the city headers, the tier and travelers controls move every total, "Add to
  plan" files a Planned food line that raises planned/projected and not spent,
  a second visit shows the plan instead of the button, and unsetting
  `ANTHROPIC_API_KEY` makes the section disappear rather than error.
