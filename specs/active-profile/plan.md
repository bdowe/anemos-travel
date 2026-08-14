# Plan: Active Travel Profile (fitness, outdoor intensity, companions)

> HOW. See `spec.md` for what/why. Repo conventions: `../../CLAUDE.md`.

## Technical Approach

Three nullable text enum columns on `traveler_preferences`, cloned from the
`work_style` pattern (`specs/work-style`, migration 00060): an allowed-values
map per field plus the shared `normalizeChoice` boundary that all three writers
(PUT handler, `save_preferences` tool, profile distiller) already pass through.

```
fitness_routine    gym | running | both | none
outdoor_intensity  easy | moderate | challenging
companions         solo | partner | friends | family_with_kids | varies
```

Zen (`docs/zen.md`), applied deliberately in four places:

1. **Explicit over implicit — companions stops being prose.** It is a fixed
   five-value fact the quiz already collects, stored as a `- Travels with: X`
   bullet inside `profile_notes` only because no column existed. The distiller
   rewrites notes wholesale on every trip, so the fact is one rewording away
   from vanishing. It gets a column, the migration moves existing values into
   it, and `profileNotesInstruction` stops naming companions so the agent has
   exactly one place to put it.
2. **Refuse the temptation to guess.** `pace` says how packed a day is; nothing
   said how hard. `outdoor_intensity` is a separate axis, not a widening of
   pace.
3. **A contract the model consumes must make wrong guesses fail loudly.** Every
   intensity band carries the same rule: state distance, elevation gain and
   rough time. A mismatch then shows up as a number the traveler can reject,
   instead of prose that reads fine either way.
4. **One obvious way to do it.** `gym`/`running` live in the structured field,
   so they are deliberately *not* added to the interest bank — a traveler must
   not have two places to say the same thing. The bank grows only with tastes
   it genuinely lacks (`cycling`, `climbing`, `national parks`).

**Migration number: `00062`.** 00061 (`expense_booking_link`) is the highest in
tree and no open PR claims higher. 00058 remains permanently burned
(`docs/parallel-dev.md` §4a).

**Prompt-cache:** three properties added to `savePrefsTool` change the
tools-block bytes → one-time cache invalidation, exactly as `work_style` did.
**Registry order is untouched — no new tool** (see Rejected below), so
`TestPlanSessionToolsOrderStable` stays green; `basePrompt` is untouched, so
`TestSystemPromptEnglishUnchanged` stays green.

## Rejected alternatives (recorded per `docs/zen.md`)

- **A `find_gyms` agent tool** mirroring `find_parking`/`SearchParkingNearby`
  (`type=gym`, tight radius). Rejected: `search_nearby` already does
  location-biased place search, so the marginal gain is a type filter, paid for
  with prompt-cache-prefix bytes and a registry tail append. The `gym` guidance
  instructs the agent to call `search_nearby` with the stay's coordinates
  instead. Revisit only if the free-text results prove poor in practice.
- **Fitness as a multi-select tag list.** Rejected: it would be structurally
  identical to the interest bank, re-creating the two-places-to-say-it problem.
  `gym`/`running` are the routines that recur regardless of city; yoga,
  swimming and climbing are tastes and belong in the bank.
- **Folding intensity into pace or into a single "how active" field.** Rejected:
  a gym-goer who wants gentle sightseeing is a coherent profile that a merged
  axis cannot express.

## Go API Changes

`src/packages/api/`, in order:

1. `migrations/00062_active_profile.sql` — Up adds the three `text` columns with
   value comments, then backfills `companions` from the `- Travels with: X`
   bullet in `profile_notes` and strips **only** the bullets it successfully
   matched. An unmatched/reworded line keeps its bullet and leaves `companions`
   NULL, so neither branch loses information. Down drops the columns; the notes
   edit is not reversible (noted in a comment — Down is dev-only here).
   No CHECK constraints: every enum on this table is enforced in Go at the one
   shared boundary, deliberately (`specs/work-style/spec.md`).
2. `query/preferences.sql` — three columns in the INSERT list, `sqlc.narg(...)`
   in VALUES, `COALESCE` lines in `ON CONFLICT DO UPDATE`. Then `make api-sqlc`.
3. `preferences_handler.go` — `allowedFitnessRoutines`, `allowedOutdoorLevels`,
   `allowedCompanions`; the three fields on `PreferencesResponse` /
   `PutPreferencesRequest` / `toPreferencesResponse`; `normalizeChoice` calls
   (400 on invalid) + upsert params.
4. `plan_handler.go` — `personalizedSystemPrompt` gains a parts entry per field
   plus behavioral notes modeled on `workNote`/`homeNote`:
   - `fitnessNote` — `gym`: prefer stays with an on-site or short-walk gym and
     say which; otherwise call `search_nearby` with the stay's coordinates and
     name a real gym plus drop-in/day-pass availability; leave an early block
     free. `running`: a specific named route per stay with a rough distance,
     and say when a neighborhood is poor for it; same free block. `both`: both.
     `none`: parts line only (mirrors `leisure_only`). Non-`none` values also
     instruct adding the kit via the existing `add_packing_item` tool.
   - `outdoorNote` — easy / moderate / challenging bands, each carrying the
     state-distance-elevation-time rule.
   - `companionsNote` — solo (don't assume a second traveler in prices or
     rooms), family_with_kids (shorter transfers, age limits, long queues),
     friends (group tables, shared apartments); partner/varies: parts line only.
5. `plan_handler.go` — `profileNotesInstruction` drops "travel companions" from
   its list of durable facts to record in notes (it has a column now).
6. `plan_tool_registry.go` — three properties on `savePrefsTool`;
   `runSavePreferencesTool` wires input struct → normalize (silent-drop on
   invalid, tool-path precedent) → upsert → `changed` list. **No registry
   entry.**
7. `profile_distiller.go` — mirror in the `update_traveler_profile` schema,
   result struct, normalize/upsert, all-nil early return; `distillSystemPrompt`
   gains the three field names and drops companions from its free-text list.
8. `plan_compactor.go` — the preserve-list prose already keeps "the travelers
   (count, names, relationships)"; extend that clause rather than duplicating
   it, and add fitness/outdoor constraints alongside the work-day clause.
   Nothing enforces this — it is the step most easily forgotten.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- `models/traveler_preferences.dart` — `fitnessRoutine`, `outdoorIntensity`,
  `companions` with `@JsonKey` snake_case names + `make flutter-build-models`.
- `services/preferences_api_service.dart` — three named params + PUT body keys.
- `providers/preferences_provider.dart` — `save()` passthrough.
- `screens/preferences_screen.dart` — three `ChoiceChipRow` sections (the widget
  already handles single-select, re-tap-to-clear and a `labelBuilder`), seeded
  in `_load()`, passed in `_save()`. Order: Budget · Pace · Work & travel ·
  **Who you travel with** · Interests · **Getting active** · Home airport ·
  Profile notes.
- `screens/onboarding_quiz_screen.dart` — `_stepCount` 6→7 with the new
  "Getting active" step after Interests; `_companionOptions` moves to
  snake_case canonical values re-keyed onto the **existing** `quizCompanion*`
  ARB strings; `buildOnboardingProfileNotes` drops its `companions` param
  entirely; **`_seedFrom` seeds all three** (retake wipe guard — the recurring
  trap from the work-style lane, and companions is not seeded today at all);
  `_finish` passes all three.
- `constants/interest_bank.dart` — `cycling`, `climbing`, `national parks`
  inserted at **index 24** (after `skiing`, before `road trips`) to keep the
  curated adjacency rule *and* the three order pins in
  `test/interest_picker_test.dart`; three `interestLabel` arms.
- l10n: `prefsFitnessRoutine{,Gym,Running,Both,None}`,
  `prefsOutdoorIntensity{,Easy,Moderate,Challenging}`, `prefsCompanions`,
  `quizActiveTitle`, `quizActiveSubtitle`, and `prefsInterest{Cycling,Climbing,
  NationalParks}` in `app_en.arb` + `app_es.arb`; regen committed.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| `fitness_routine` | `*string` (`PreferencesResponse`/`PutPreferencesRequest`) | `String? fitnessRoutine` | yes | ✓ |
| `outdoor_intensity` | `*string` (both) | `String? outdoorIntensity` | yes | ✓ |
| `companions` | `*string` (both) | `String? companions` | yes | ✓ |

## Cross-cutting

- No new env vars, routes, endpoints or gateway config.
- No new agent tool; registry order and `basePrompt` untouched.
- Five test fakes `implements PreferencesApiService` must gain the three named
  params: `settings_polish_test.dart`, `onboarding_quiz_test.dart`,
  `trip_detail_home_legs_test.dart`, `secondary_width_sweep_test.dart`,
  `trip_detail_stay_dates_test.dart`.
- `trip_detail_screen.dart` is **not** touched (hub-file lane rule).

## Verification

- `make api-fmt && make api-vet`; `go test ./...` (lane test DB via
  `make test-db`).
- `make flutter-build-models && make flutter-gen-l10n`; `make flutter-analyze`;
  `make flutter-test`.
- Migration: a row seeded with `- Travels with: family with kids` ends with
  `companions = 'family_with_kids'` and no `- Travels with:` line; a row with
  `- Travels with: my partner` keeps its bullet and stays NULL.
- Manual, on the lane stack: save all three on the profile and reload; retake
  the quiz and confirm every chip is pre-selected; plan a 3-day trip and check
  the reply names a real gym, leaves a morning block, gives distance/elevation
  for outdoor suggestions, and lands training kit in the packing list; say
  "I run every morning" and confirm the profile-updated notice plus the changed
  chip.
