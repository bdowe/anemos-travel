# Tasks: Active Travel Profile (fitness, outdoor intensity, companions)

> Dependency-ordered; single lane (`active-profile`), migration **00062**
> reserved. `[P]` marks tasks that can run in parallel within the lane.

## API (Go)

- [x] Migration `00062_active_profile.sql` — Up: three `ADD COLUMN`s with value
      comments, companions backfill from the `- Travels with:` bullet, strip of
      matched bullets only; Down: drop the three columns (notes edit noted as
      irreversible)
- [x] `query/preferences.sql`: three columns in INSERT + `sqlc.narg` + COALESCE
      lines; `make api-sqlc`
- [x] `preferences_handler.go`: `allowedFitnessRoutines` /
      `allowedOutdoorLevels` / `allowedCompanions`, wire structs,
      `normalizeChoice` calls, upsert params, `toPreferencesResponse`
- [x] `plan_handler.go`: `personalizedSystemPrompt` parts + `fitnessNote` /
      `outdoorNote` / `companionsNote` per value
- [x] `plan_handler.go`: drop "travel companions" from `profileNotesInstruction`
- [x] `plan_tool_registry.go`: three `savePrefsTool` properties +
      `runSavePreferencesTool` wiring (input/normalize/upsert/changed). **No
      registry entry — order untouched.**
- [x] `profile_distiller.go`: tool schema + result struct + normalize/upsert +
      all-nil guard + prose (and drop companions from its free-text list)
- [x] `plan_compactor.go`: extend the travelers clause + add fitness/outdoor
      constraints to the preserve-list prose

## Models & codegen (Flutter)

- [x] `models/traveler_preferences.dart` + `make flutter-build-models`
- [x] Contract Parity table in `plan.md` checked

## UI (Flutter)

- [x] [P] `services/preferences_api_service.dart` three params + body keys
- [x] [P] `providers/preferences_provider.dart` `save()` passthrough
- [x] `screens/preferences_screen.dart`: three chip sections + seed + save
- [x] `screens/onboarding_quiz_screen.dart`: `_stepCount` 6→7, new "Getting
      active" step after Interests, `_companionOptions` → snake_case,
      `buildOnboardingProfileNotes` drops its `companions` param, **`_seedFrom`
      seeds all three**, `_finish` passes all three
- [x] [P] `constants/interest_bank.dart`: `cycling` / `climbing` /
      `national parks` at index 24 + three `interestLabel` arms
- [x] l10n keys en+es + `make flutter-gen-l10n`, regen committed

## Tests

- [x] `preferences_handler_test.go`: accept/reject per field
- [x] `plan_handler_test.go`: one `personalizedSystemPrompt` case per enum
      value + unset-is-absent
- [x] Migration backfill: matched bullet → value + bullet removed; reworded
      bullet → NULL + bullet kept
- [x] `onboarding_quiz_test.dart`: step pins 6→7, new step renders, retake
      seeds all three (incl. companions, which is new behavior)
- [x] `interest_picker_test.dart`: order pins still hold at 33 values
- [x] Five `implements PreferencesApiService` fakes gain the three params:
      `settings_polish_test.dart`, `onboarding_quiz_test.dart`,
      `trip_detail_home_legs_test.dart`, `secondary_width_sweep_test.dart`,
      `trip_detail_stay_dates_test.dart`
- [x] Untouched-green: `TestPlanSessionToolsOrderStable`,
      `TestSystemPromptEnglishUnchanged`

## Ship

- [x] `make api-fmt && make api-vet && go test ./...`
- [x] `make flutter-analyze && make flutter-test`
- [x] Replaced the planned manual browser pass with automated equivalents:
      `active_profile_integration_test.go` drives PUT/GET through the real
      router (round-trip, partial-merge, `none`-is-stored, 400s), and the
      companions backfill was replayed from the shipped migration against a
      real Postgres — exact bullet → value + line stripped; reworded bullet →
      NULL + line kept; bullet-only note → NULL; no bullet → untouched.
- [ ] **Not done:** live plan-chat pass (does the agent actually name a gym,
      leave a morning block, quote distance/elevation, add kit to packing).
      Needs a real `ANTHROPIC_API_KEY` and is non-deterministic; the prompt
      *content* is pinned by `plan_handler_test.go`. Worth a look post-deploy.
- [ ] `ship pr` — stop at PR-open; the integrator merges
