# Tasks: Daily food & drink budget, per city

> Dependency-ordered. Single lane (`daily-spend-guide`) — it takes migration
> **00070**, touches neither `trip_detail_screen.dart` nor
> `plan_tool_registry.go`, and owns the `budgetDaily` ARB prefix.

## ⚠ MERGE ORDER — 00070 must not land before 00070

This lane originally took **00070** and yielded it. Lane `trip-description`
(commit `af1fb44`) had already committed a `00070`, but **deliberately did not
open its PR** (it is held pending #442), so `gh pr list --json files` — the
check the 00066 collision taught us to run — could not see it. *An unopened
lane is invisible to every automated reservation check there is; the only
record was a memory note.*

**The constraint is hard, not cosmetic.** `db.go` runs `goose.Up` without
`WithAllowMissing`, so goose refuses a version below the database's current max
and `main.go` escalates that to `log.Fatalf` — the API exits before binding and
crash-loops with the old container already replaced (the 00058 incident class).
So:

- **00070 (trip-description) must merge and deploy BEFORE 00070 (this lane).**
- If 00070 lands first for any reason, trip-description must renumber to 00072
  before it merges.

CI cannot catch this: its guard compares each branch against **main's** highest
(00069 today), and both 00070 and 00070 clear that independently.

## API (Go)

- [x] Migration `00070_expense_leg_key.sql` — nullable `leg_key` + partial
      unique index on `(trip_id, leg_key, category)`
- [x] `query/trip_budgets.sql`: `CreateExpense` gains the column,
      `GetExpenseByLegKey` added, `UpdateExpense` deliberately excludes it;
      `make api-sqlc`
- [x] `daily_spend_service.go`: types, `resolveSpendTier`,
      `estimateDailyFoodSpend` + 30-day cache
- [x] `daily_spend_handler.go`: the endpoint (editorOnly, degrade-never-error)
      + `tripLegKeyExists`
- [x] `budget_handler.go`: `leg_key` on the POST and the response, the
      upsert-by-leg branch, PATCH left without a mechanism
- [x] Register the route in `main.go`
- [x] No new env var (reuses `ANTHROPIC_API_KEY`)

## Models & codegen (Flutter)

- [x] `models/daily_spend.dart`; `legKey` on `models/expense.dart`
- [x] `make flutter-build-models`
- [x] Contract Parity table in `plan.md` complete

## UI (Flutter)

- [x] `getDailySpend` + `legKey` in `services/budget_api_service.dart`
- [x] `dailySpendProvider` + `dailySpendSettingsProvider`
- [x] `utils/daily_spend.dart` — the one multiplication
- [x] `widgets/daily_spend_section.dart`, mounted from `budget_section.dart`
- [x] Loading / empty / viewer / offline all resolve to "no section"
- [x] `budgetDaily*` keys in `app_en.arb` + `app_es.arb`; `make flutter-gen-l10n`

## Tests

- [x] `daily_spend_service_test.go` — tier ladder, cache, dropped estimates,
      provider failure, no-tool-call
- [x] `daily_spend_integration_test.go` — endpoint shape, nights parity with
      `computeTripLegs`, tier resolution, the three degrade paths, editor-only,
      and the leg-keyed expense (upsert, unknown key, conflicting key, PATCH)
- [x] `budget_api_service_test.dart` — the wire oracle: the daily-spend path and
      the `leg_key` body field
- [x] `daily_spend_test.dart` — the multiplication, including the
      nights-reconcile case
- [x] `budget_section_test.dart` — rows, stepper, tier, accept, already-planned,
      lookalike label, viewer/offline, Spanish at 360px
- [x] Mutation-checked: matching by label instead of leg key fails a test

## Verification

- [x] `make api-fmt && make api-vet` clean
- [x] `go test ./...` green against the lane DB
- [x] `make flutter-analyze` clean (3 pre-existing `route_response.dart` infos)
- [x] `make flutter-test` green
- [x] Manual end-to-end via the lane gateway (headless Chrome, real Anthropic
      key): 00070 applied on boot; a real Portugal trip returned Lisbon $35 /
      Porto $32 per person per day at `mid`, with nights 3 and 4 **matching the
      city header chips**; tiers moved sensibly (budget 28/26, luxury 85/75);
      an unknown tier 400'd; the travelers stepper took Porto $128 → $256;
      "Add to plan" filed a Planned food line (planned 466, spent 0) and both
      cities then showed the plan instead of a button; a repeat POST returned
      the same row. **Found and fixed by looking**: the model returns the same
      `includes` phrase for every city, so per-row it was pure repetition — now
      stated once, the `summarizeHotels` treatment.
- [ ] Dogfood on prod and log the result in `docs/friction-log.md`
