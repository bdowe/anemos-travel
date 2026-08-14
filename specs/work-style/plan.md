# Plan: Work Style (Digital-Nomad Travel Support)

> HOW. See `spec.md` for what/why. Repo conventions: `../../CLAUDE.md`.

## Technical Approach

One nullable text enum column `traveler_preferences.work_style` ∈
`digital_nomad | workation | leisure_only`, cloned from the `budget`/`pace`
pattern: allowed-values map + the shared `normalizeChoice` boundary that all
three writers (PUT handler, `save_preferences` tool, profile distiller) pass
through. Zen: explicit over implicit — a structured column, not a
`profile_notes` bullet (the distiller rewrites notes and could drop it);
meaning documented in a schema comment, enforced in exactly one place. The
plan-chat integration is an explicit new branch in `personalizedSystemPrompt`
(field enumeration there is deliberate; nothing flows automatically), with a
behavioral note per value modeled on the existing home-airport note.

**Migration number: `00060`.** 00059 shipped with uptime-history; no open PR
claims anything higher. (00058 was skipped as reserved; it is now permanently
burned — see `docs/parallel-dev.md` §4a.)

**Prompt-cache:** adding a property to `savePrefsTool` changes the tools-block
bytes → one-time cache invalidation (acceptable, same as every prior field).
Registry order untouched; `basePrompt` untouched, so the anonymous-prompt pin
(`TestSystemPromptEnglishUnchanged`) stays green.

## Go API Changes

`src/packages/api/` in order:

1. `migrations/00060_work_style.sql` — `ADD COLUMN work_style text` with a
   value comment; Down drops it.
2. `query/preferences.sql` — column in INSERT list, `sqlc.narg('work_style')`
   in VALUES, `COALESCE` line in `ON CONFLICT DO UPDATE`. Then `make api-sqlc`.
3. `preferences_handler.go` — `allowedWorkStyles` map; `WorkStyle *string`
   on `PreferencesResponse` / `PutPreferencesRequest` / `toPreferencesResponse`;
   `normalizeChoice` call (400 on invalid) + upsert param.
4. `plan_tool_registry.go` — `work_style` property on `savePrefsTool` (enum +
   description); top-level description mentions working while traveling;
   `runSavePreferencesTool` wires input struct → normalize (silent-drop on
   invalid, tool-path precedent) → upsert → `changed` list.
5. `profile_distiller.go` — mirror in `update_traveler_profile` schema, result
   struct, normalize/upsert, all-nil early return; `distillSystemPrompt` prose
   gains `work_style`.
6. `plan_handler.go` — `personalizedSystemPrompt`: parts line per value +
   `workNote` guidance (digital_nomad: wifi/workspace/longer-stays/work-block
   balance/nomad visas; workation: lighter; leisure_only: parts line only),
   appended after `homeNote`.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- `models/traveler_preferences.dart` — `@JsonKey(name: 'work_style') String?
  workStyle` + `make flutter-build-models`.
- `services/preferences_api_service.dart` — optional named param + PUT body key.
- `providers/preferences_provider.dart` — `save()` passthrough.
- `screens/preferences_screen.dart` — `_workStyles` const + label mapper +
  chip section after Pace; seed in `_load()`, pass in `_save()`.
- `screens/onboarding_quiz_screen.dart` — `_stepCount` 5→6; new step at
  PageView index 1; state + label mapper; **seed in `_seedFrom`** (retake
  wipe guard); pass in `_finish`.
- l10n: `prefsWorkStyle{,Nomad,Workation,Leisure}` + `quizWorkStyleTitle/
  Subtitle` in `app_en.arb` + `app_es.arb`; regen committed.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| `work_style` | `*string` (`PreferencesResponse`/`PutPreferencesRequest`) | `String? workStyle` | yes | ✓ |

## Cross-cutting

- No new env vars, routes, or gateway config.
- Test fakes `implements PreferencesApiService` (settings_polish_test.dart,
  onboarding_quiz_test.dart) must gain the new named param.

## Verification

- `make api-fmt && make api-vet`; `go test ./...` (lane test DB via `make
  test-db`).
- `make flutter-build-models && make flutter-analyze && make flutter-test`.
- Manual on the lane stack (gateway :3002): fresh signup → 6-step quiz, work
  question at step 2; answer nomad → profile chip set; chat reflects
  wifi/longer-stay framing; "I work remotely while I travel" in chat →
  profile_updated SSE; retake keeps the chip; Spanish strings render.
