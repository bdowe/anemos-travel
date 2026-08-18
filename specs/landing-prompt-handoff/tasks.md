# Tasks: Landing Prompt Handoff

> Dependency-ordered. PR 2, stacked on `landing-redesign` (PR 1); merge order
> UI → Handoff.

## Store

- [ ] `lib/services/pending_prompt.dart` (`PendingPrompt`,
      `PendingPromptStore` with memory mirror, `maxPromptLength`)
- [ ] `test/pending_prompt_test.dart`

## Consume point

- [ ] `url_sync.dart`: `bootTargetSeen` getter
- [ ] `lib/providers/pending_prompt_provider.dart` + `main.dart` watch
- [ ] `test/pending_prompt_resume_test.dart`

## Composer

- [ ] `chat_panel.dart` external-draft `ref.listen` + test

## Landing wiring

- [ ] `landing_handoff.dart`: real default (save → analytics → auth push);
      hero `maxLength` sourced from the store constant
- [ ] `test/landing_default_handoff_test.dart`

## Analytics

- [ ] `analytics_api_service.dart`: two methods + anonymous mirror
- [ ] Go `analytics.go` whitelists; `admin_metrics_handler.go` timeseries
- [ ] `admin_metrics_screen.dart` `_series` entry
- [ ] Go test coverage; `specs/instrumentation-events/spec.md` taxonomy

## Verification

- [ ] `flutter analyze` + `flutter test` clean
- [ ] `make api-fmt api-vet` + `go test` clean
- [ ] Browser QA: email path end-to-end; SSO path via handoff seeding

**Conflict manifest** — edits: `landing_handoff.dart`, `landing_hero.dart`,
`main.dart`, `url_sync.dart`, `chat_panel.dart`, `analytics_api_service.dart`,
`admin_metrics_screen.dart`, `analytics.go`, `admin_metrics_handler.go`,
`specs/instrumentation-events/spec.md`.
