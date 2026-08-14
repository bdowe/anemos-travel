# Tasks: Work Style (Digital-Nomad Travel Support)

> Dependency-ordered; single lane (`work-style`), migration **00060** reserved.

## API (Go)

- [ ] Migration `00060_work_style.sql` (Up: `ADD COLUMN work_style text` +
      value comment; Down: drop)
- [ ] `query/preferences.sql`: INSERT column + `sqlc.narg` + COALESCE line;
      `make api-sqlc`
- [ ] `preferences_handler.go`: `allowedWorkStyles`, wire structs,
      `normalizeChoice`, upsert param
- [ ] `plan_tool_registry.go`: `savePrefsTool` property + description tweak +
      `runSavePreferencesTool` wiring (input/normalize/upsert/changed)
- [ ] `profile_distiller.go`: tool schema + result struct + upsert + prose
- [ ] `plan_handler.go`: `personalizedSystemPrompt` parts + workNote per value

## Models & codegen (Flutter)

- [ ] `models/traveler_preferences.dart` + `make flutter-build-models`
- [ ] Contract Parity row in `plan.md` checked

## UI (Flutter)

- [ ] [P] `services/preferences_api_service.dart` param + body key
- [ ] [P] `providers/preferences_provider.dart` `save()` passthrough
- [ ] `screens/preferences_screen.dart`: chips section + seed + save
- [ ] `screens/onboarding_quiz_screen.dart`: step 2 of 6, `_seedFrom`,
      `_finish`
- [ ] l10n keys en+es + regen committed

## Tests

- [ ] `plan_handler_test.go`: digital_nomad / workation / leisure_only prompt
      cases
- [ ] `preferences_handler_test.go`: allowedWorkStyles accept/reject
- [ ] `onboarding_quiz_test.dart`: step pins 5→6, back-gesture step-2 text,
      chip render + save + retake seed
- [ ] `settings_polish_test.dart`: fake signature
- [ ] Untouched-green: `TestPlanSessionToolsOrderStable`,
      `TestSystemPromptEnglishUnchanged`

## Verification

- [ ] `make api-fmt && make api-vet` clean; `go test ./...` green
- [ ] `make flutter-analyze` clean; `make flutter-test` green
- [ ] Manual on lane stack (:3002): 6-step quiz → profile chip → nomad-aware
      chat → chat-save → retake seed → Spanish
- [ ] `ship pr` — stop at PR-open
