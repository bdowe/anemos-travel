# Tasks: Spanish Localization (i18n)

> Dependency-ordered by PR. `[P]` = parallelizable with its siblings.
> Spanish stays invisible to users until PR 7, so PRs 1-6 ship independently.

## PR 1 — Server locale foundation

- [x] Write `spec.md` + `plan.md`
- [x] Migration `00049_user_locale.sql` (`users.locale TEXT`, nullable)
- [x] `query/users.sql`: `UpdateUserProfile` partial-update query; `make api-sqlc`
- [x] `i18n.go`: `supportedLocales`, `normalizeLocale`, `matchLocale`,
      `localeMiddleware`, `requestLocale`, `tr`, `localizedDate`, `languageName`
- [x] Register `localeMiddleware` in `main.go`
- [x] `patchAccountHandler` accepts + validates `locale`
- [x] `UserResponse`/`toUserResponse` expose `locale`
- [x] Unit tests: locale matching, catalog fallback + completeness, dates
- [x] Integration test: locale round-trips PATCH → `/auth/me`; invalid rejected
- [x] `make api-fmt && make api-vet` clean

## PR 2 — Flutter i18n infrastructure

- [x] `pubspec.yaml`: `flutter_localizations`, `intl`, `generate: true`
- [x] `l10n.yaml` + `lib/l10n/app_en.arb` + `lib/l10n/app_es.arb` (shell strings)
- [x] `lib/l10n/l10n.dart` — `context.l10n` extension + `kSupportedLocales`
      (single source of truth; `es` added here in PR 7)
- [x] `lib/providers/locale_provider.dart` — override persistence, effective
      locale, `Intl.defaultLocale`, account sync
- [x] `main.dart` — delegates, `supportedLocales: [en]` (es deferred to PR 7)
- [x] `services/api_client.dart` — `Accept-Language` in `jsonHeaders()`;
      `account_api_service.dart` — `updateLocale`
- [x] Auth user model gains `locale`; `make flutter-build-models`
- [x] [P] `utils/trip_format.dart` → `DateFormat` (signatures unchanged)
- [x] [P] `utils/money_format.dart` → `NumberFormat` digit grouping
- [x] Tests: locale resolution, `Accept-Language` header, Spanish date/number
      formatting; `flutter analyze` CI-clean; 395 tests pass
- [x] CI gate: `flutter gen-l10n` + untranslated-messages check + l10n drift
      check (mirrors the Go sqlc drift check)

## PRs 3-5 — String extraction (mechanical)

**PR 3 (batch A) is DONE**: preferences, auth, reset-password, landing, verify,
sso-callback, account-settings, onboarding-quiz + the three SSO button widgets.
109 keys. splash_screen has no user-facing text (left untouched).
Established for batches B and C:
- `test/support/l10n_test_app.dart` — any test pumping a bare `MaterialApp`
  needs the delegates or `AppLocalizations.of` throws; supports pinning `es`.
- Canonical API values (chip options) keep their values and get translated
  labels only, via `ChoiceChipRow.labelBuilder` + a `_xLabel` switch helper.
- Strings assigned outside `build` (e.g. from `initState`) must become an enum
  or bool that `build` maps to copy — `context.l10n` is illegal there.
- Extraction was parallelized across agents writing `lib/l10n/_frag_*.json`
  fragments (no shared-ARB contention), verified English-verbatim against
  `git HEAD` before merging.

**PR 4 (batch B) is DONE**: trip detail (5,310 lines), trips list, home, shell,
bookings, budget, checklist, item dialog, health, review, map, account menu,
booking-todo card, add-to-calendar. 378 keys (541 total). Also removed the now
dead `NavDestinationData.label`, and collapsed duplicate offline/error copy into
`commonOffline`/`commonGenericError`.

Learned in batch B, for batch C:
- Giving a **ConsumerWidget** a Localizations dependency makes
  `didChangeDependencies` fire on reparenting (e.g. inside a
  `ReorderableListView`), which triggers a Riverpod container lookup that a
  `ProviderScope`-less test never made before. Latent-missing `ProviderScope`
  in tests surfaces as `Bad state: No ProviderScope found` — add the scope.
- Strings that are ALSO API payloads or seed the AI prompt stay English
  (`'Stay in {city}'` booking-draft names, `_buildSectionSeed`). Translating
  them would make stored data locale-dependent.
- `_months`/`_weekdays` tables in trip_detail feed day headers and are still
  English — see the DateFormat follow-up below.

Per batch (A: auth/landing/settings/preferences/account · B: trips/itinerary/
today/budget/checklist · C: chat/alerts/share/export/remaining):

- [ ] Replace literals with `context.l10n.*`
- [ ] Add character-identical English entries to `app_en.arb`
- [ ] Add reviewed Spanish entries to `app_es.arb`
- [ ] Refactor strings built outside widget context (provider/service SnackBar
      messages) to keys rendered at the widget layer
- [ ] Layout spot-check under a temporary Spanish override (~25% expansion)
- [ ] `make flutter-analyze && make flutter-test` clean

- [x] After PR 5: `untranslated-messages` output is empty

**PR 5 (batch C) is DONE**: chat panel, agent screen, refine panel, alerts,
create-alert sheet, notification center, shared trip, legal links, offline
banner, place search, add-to-trip, route optimizer, optimization params, flight
search/card/details, airport field, guides, guide detail, app map. 245 keys
(786 total). Every non-admin user-facing file in `lib/` now reads its copy from
the ARB.

Also in PR 5:
- `trip_detail_screen`'s `_months`/`_weekdays` tables became `DateFormat.MMMd()`
  / `MMMEd()` (the batch-B follow-up; English byte-identical, Spanish reorders
  to "15 jul" / "mié, 15 jul" on its own).
- Flight stop labels moved off `FlightOffer` into `utils/flight_labels.dart` as
  an ICU plural — a model getter returning a fixed English sentence cannot
  express "1 escala" vs "2 escalas".
- `DictationController` and `add_to_trip_sheet` now store error *codes* (enums)
  resolved to copy in `build`, since services and `initState` have no context.
- Suggestion chips send the localized text on BOTH the home and agent screens.
  They become a message in the traveler's own transcript, so an English message
  they never wrote reads as a bug. `RefineTarget.label` still stays English —
  that one goes into the AI seed prompt, not the transcript.
- Fixed a latent crash: `context.l10n` read after an `await` in
  trip_detail's booking-link handler (only an `info` lint, but a real
  unmounted-widget throw).

## PR 6 — Server-side Spanish + AI + providers

- [x] Catalog entries for all server-rendered strings
- [x] Email builders take a `locale` param: verification, reset, inline verify
      pages, invites, trip reminders, weekly nudges, price alerts
- [x] Email jobs read `users.locale` (queries join the column)
- [x] `trip_review.go` — findings, fix labels, localized dates
- [x] `print_view_handler.go` + `share_preview_handler.go` — `<html lang>`,
      labels, `?lang=` param; `calendar_handler.go` — time-of-day labels
- [x] **Calendar event titles must flip client- and server-side together.**
      `bookings_section.dart` builds Google-link titles (`Stay: {name}`, the
      transport `_segmentCalendarTitle`) that deliberately mirror the Go `.ics`
      export. PR 4 left them in English on purpose: translating only the client
      would make the Google link disagree with the downloaded `.ics`. Localize
      both in this PR, in one change.
- [x] `notifications_writer.go` — fallback actor string
- [x] `plan_handler.go` — Spanish instruction appended only when locale != en
      (`basePrompt` and `plan_tool_registry.go` untouched)
- [x] [P] Provider language params: `places_service.go`, `events_service.go`,
      `weather_service.go` (un-hardcode `language=en`)
- [x] Tests: es email builders, Spanish trip-review integration test, and the
      **English prompt byte-stability** test via the fake-Anthropic harness
- [x] `make smoke`

## Deliberately not localized

- **Admin-only screens** (`local_admin_screen.dart`, `admin_metrics_screen.dart`
  and the `daily_count_chart` they use, ~38 strings). They sit behind
  `isAdmin`, which is a single English-speaking operator. Translating internal
  tooling buys nothing and adds permanent translation debt on every change.
- `local_rec_card.dart` has zero user-facing English — every string is server
  data (name, quote, tip, credit line).

## Follow-ups (not blocking enablement)

- [ ] `trip_detail_screen.dart` still has private `_months`/`_weekdays` tables
      (`'Jan'…'Dec'`, `'Mon'…'Sun'`) feeding `_fmtDayHeader`/`_fmtShortDt`.
      These are date-format data, not copy — convert to `intl DateFormat` the
      way `utils/trip_format.dart` was in PR 2, rather than adding 19 ARB keys.
      Day headers would otherwise stay English under `es`.
- [ ] `add_itinerary_item_dialog` prefill `initialName: 'Stay in {city}'` is
      visible in a text field but is also the persisted booking name. Localizing
      it needs a display/value split, not a translation.
- [ ] `RefineTarget.label` (`widgets/trip_refine_panel.dart`) is interpolated
      into localized trip-detail copy and stays English until batch C.
- [ ] Copy change (deliberately deferred from PR 3): the budget/pace/interest
      chips render lowercase `budget`/`mid`/`luxury`. Capitalizing them is an
      English-visible change, so it does not belong in an extraction PR.

**PR 6 notes:**
- 131 catalog keys. `TestSystemPromptEnglishUnchanged` is the load-bearing test:
  English (and no-header, and unsupported-locale) requests must produce a prompt
  with no language instruction, and Spanish must be exactly the English prompt
  plus a suffix, so the cached prefix provably never moved.
- Signup now persists the negotiated locale in `CreateUser` (email + both SSO
  paths), so the very first verification email is already in the right language
  instead of waiting for the client's first sync.
- Calendar titles are a cross-language contract, pinned from BOTH sides:
  `api/calendar_event_test.go` and `flutter-app/test/calendar_title_parity_test.dart`.
  Unified the Spanish ferry term ("ferri") across the three mode label sets.
- Email dates stay ISO (`2026-09-01`). Localizing them would change the ENGLISH
  body, which the character-identical rule forbids; ISO is unambiguous in both
  languages. A deliberate copy change, not an extraction change.
- Still English by design: `FindingFix.PackingItem` values (they are written to
  the packing list as data — localizing belongs to that write path), and
  `weather_service.go`'s `summarizeWeather` string, which is agent-facing.

## PR 7 — Enablement

- [x] `es` added to `kSupportedLocales` (`lib/l10n/l10n.dart` — the single
      source of truth, so MaterialApp, the provider and the picker all follow)
- [x] Language picker in `account_settings_screen.dart`
      (System default / English / Español), built from `kSupportedLocales`
      rather than hardcoded. Uses the current `RadioGroup` API, not the
      deprecated `RadioListTile.groupValue`.
- [x] Tests: picking Spanish redraws the app, the choice survives a relaunch,
      "System default" clears the override, and the API language header follows
- [x] Verified against the live dev stack: signup with `Accept-Language: es`
      persists `users.locale = es`; `/share-preview` returns `<html lang="es">`
      with translated copy; the built web bundle contains the Spanish strings
- [ ] `make smoke` (run against a deployed build)

**Remaining follow-ups** (all recorded above, none blocking): `PackingItem`
values, `weather_service.go`'s `summarizeWeather`, email dates staying ISO, and
the lowercase budget/pace chip labels.

## PR 8 — Visible language switcher

- [x] Amend spec.md: app-bar globe menu on Home / landing / sign-in
- [x] `l10n.dart`: shared `languageDisplayName`; retire `_LanguagePicker._nameFor`
- [x] `widgets/language_menu_button.dart` — globe `PopupMenuButton`, checked on
      the override, entries from `kLocaleSystem` + `kSupportedLocales`
- [x] ARB: `languageMenuTooltip` (en + es); `flutter gen-l10n`, drift-free
- [x] Mount in Home, landing and auth app bars (all widths — no rail gate)
- [x] Tests: `language_menu_button_test.dart`; `flutter analyze` clean
