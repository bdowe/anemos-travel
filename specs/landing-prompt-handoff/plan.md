# Plan: Landing Prompt Handoff

> **HOW.** Stacked on `specs/landing-redesign/` (branch `landing-prompt-handoff`
> on `landing-redesign`).

## Technical Approach

Three pieces, each cloned from a proven precedent:

1. **`PendingPromptStore`** (`lib/services/pending_prompt.dart`) — structural
   clone of `PendingConnectStore`: SharedPreferences keys
   `pending_prompt.{text,chip,saved_at}` (SharedPreferences IS localStorage on
   web, which is what survives the SSO full-page reload), 30-min expiry,
   `take()` single-use clearing before validating, every method best-effort.
   One addition: a static in-memory write-through mirror so the email path
   (no reload) survives private-browsing storage failure; `take()` validates
   the mirror's age too. `maxPromptLength = 2000` matches the hero field's
   `maxLength` (`kLandingPromptMaxLength` — moved to the store as the one
   source of truth, hero imports it).
2. **`pendingPromptResumeProvider`** (`lib/providers/pending_prompt_provider.dart`)
   — the ONE consume point, modeled on `urlSyncProvider`'s boot-target
   consumption: `ref.listen(authProvider)` + a post-frame initial check,
   eligibility `initialized && isSignedIn && !needsOnboarding`,
   reentrancy-guarded. On eligible: `take()` → write
   `chatDraftProvider(chatDraftKeyFor(null))` (prefill, never send) → switch
   `navIndexProvider` to Plan **unless** `UrlSyncController.bootTargetSeen`
   (new 2-line getter) — a deep-linked destination outranks the tab
   preselect — → record `pending_prompt_consumed`. Watched from frame 1 in
   `TravelRoutePlannerApp.build` next to `rootUrlObserverProvider`, so it is
   alive on the bare `/sso` route and needs **zero changes** to AuthScreen or
   sso_callback_screen. Covers all paths: email sign-up (quiz completes →
   state flips → listener), SSO (prefs survive the reload), sign-in, cold
   boot.
3. **`ChatPanel` external-draft listener** — one `ref.listen` on
   `chatDraftProvider(_draftKey).select((d) => d.text)` in build, applying
   external writes to `_controller` (guard `next == _controller.text`; the
   `_saveDraft` echo makes own keystrokes equal, so the loop terminates; the
   `TextEditingValue` idiom from `_restoreDraft`). Today an external draft
   write to a MOUNTED composer silently does nothing — this closes the only
   silent-loss window and makes the consume correct regardless of listener
   -vs-build ordering.

The landing side already exposes the seam: `landingPromptHandoffProvider`'s
default in `lib/screens/landing/landing_handoff.dart` becomes the real
implementation — `await store.save()` BEFORE any navigation (the
`connect_app_screen.dart:111` rule), best-effort
`recordLandingPromptSubmitted`, then the same `warmSsoAvailability` +
`pushOnce(AuthScreen(initialIsLogin: false))`.

**Analytics** rides the existing closed metadata keys — `surface: hero|card`
(NOT `source`, whose value set is closed for itinerary_item_added) and
`kind: <destination slug>` for cards; the prompt text never rides.

## Go API Changes

- `analytics.go`: `landing_prompt_submitted` + `pending_prompt_consumed` in
  `clientEventTypes`; `landing_prompt_submitted` also in
  `anonymousClientEventTypes` (a signed-out visitor produces it). No
  metadata-key changes.
- `admin_metrics_handler.go`: `landing_prompt_submitted` in
  `timeseriesEventTypes` after `landing_viewed` (funnel order).

## Flutter Changes

- NEW `lib/services/pending_prompt.dart`, `lib/providers/pending_prompt_provider.dart`.
- `lib/navigation/url_sync.dart`: `bootTargetSeen` getter.
- `lib/widgets/chat_panel.dart`: the external-draft `ref.listen` (only).
- `lib/screens/landing/landing_handoff.dart`: real default handoff.
- `lib/screens/landing/landing_hero.dart`: `kLandingPromptMaxLength` now
  re-exported from the store constant.
- `lib/services/analytics_api_service.dart`: `recordLandingPromptSubmitted`
  (+ anonymous mirror entry), `recordPendingPromptConsumed`.
- `lib/main.dart`: one `ref.watch(pendingPromptResumeProvider)`.
- `lib/screens/admin_metrics_screen.dart`: `('landing_prompt_submitted',
  'Prompts submitted')` in `_series`.
- `specs/instrumentation-events/spec.md`: taxonomy additions.

## Contract Parity

No new JSON shapes; the events payload is unchanged (existing
`event_type`/`metadata` contract).

## Cross-cutting

None (no env vars, no gateway changes, no migrations).

## Verification

- `flutter analyze` + full `flutter test`; `make api-fmt api-vet` + Go
  analytics tests.
- New tests: store unit tests (clone of `pending_connect_test.dart` +
  truncation + memory mirror), resume-provider tests (consume on transition;
  withheld while `needsOnboarding`; stale → nothing; `bootTargetSeen` skips
  the tab switch; single-use), default-handoff widget test (store written +
  event recorded + AuthScreen pushed in sign-up mode), ChatPanel
  external-draft test, Go whitelist/timeseries assertions.
- Browser QA on the lane stack: type → submit → email sign-up → quiz →
  Plan tab composer prefilled; same via SSO handoff-seeded sign-in.
