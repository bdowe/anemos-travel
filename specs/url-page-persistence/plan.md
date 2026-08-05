# Plan: URL Page Persistence

> **HOW.** See `spec.md` for what & why. Flutter-only change; no Go, no nginx
> (the deployment gateway already SPA-falls-back `/app/*` to the shell —
> `dockerize/deployment/nginx/snippets/app-locations.conf`).

## Technical Approach

Stay on Navigator 1.0 (no go_router/Router migration — the shell's nested
tab navigators with app-lifetime GlobalKeys make that a rewrite). Two halves:

1. **Write half**: a single source-of-truth location (`UrlSyncController`)
   fed by NavigatorObservers on the three tab navigators + `navIndexProvider`
   changes + the plan chat id, reported to the browser with
   `SystemNavigator.routeInformationUpdated(uri:, replace: true)` behind a
   test-overridable `urlReporterProvider`.
2. **Read half**: `generateRoute` parses the new paths into a `BootTarget`
   carried through `AuthGate`; the controller consumes it once when auth
   resolves signed-in-and-onboarded — sets the tab, then bounded-retry-pushes
   the inner screen (the `shared_trip_screen.dart` deep-link pattern).

### Flutter 3.35.4 SDK facts this design rests on (re-verify on SDK bumps)

Local, CI (`.github/workflows/ci.yml`), and both Dockerfiles all pin 3.35.4.

- `SystemNavigator.routeUpdated` **no longer exists**; the framework calls
  `routeInformationUpdated`, which does **not** switch the engine's history
  mode — in single-entry mode it *replaces* the browser entry (URL updates, no
  history stack).
- Single-entry mode is guaranteed: `WidgetsApp` sets
  `reportsRouteUpdateToEngine: true` and the root Navigator's `initState`
  calls `SystemNavigator.selectSingleEntryHistory()`.
- The framework's own auto-report fires **only for named routes**, so the
  unnamed `TripMapScreen` root push reports nothing. Naming it would be
  harmful (its pop would re-report the boot route's name). The only post-boot
  auto-reports are the five `pushNamedAndRemoveUntil('/')` reset sites.
- Riverpod 2.6.1 forbids provider writes during build/initState → the boot
  tab is applied from an auth-state **listener** (outside the build phase,
  before the shell's first frame — no home-tab flash).
- Boot-URL test seam:
  `tester.binding.platformDispatcher.defaultRouteNameTestValue`.

### Hard invariant

`generateInitialRoutes` must keep producing **exactly one** route (double
AppShell mount = blank screen; commit ff3c907, locked by
`test/deep_link_initial_routes_test.dart`).

## URL grammar (single source: `lib/navigation/app_routes.dart`)

| Location | Written when | Boot restore (signed in) |
|---|---|---|
| `/` | home tab at root | shell, home tab |
| `/plan` | plan tab, no chat yet / after reset | shell, plan tab |
| `/plan/<chatId>` | plan tab once a chat exists | plan tab + transcript resume; failure → fresh plan tab |
| `/trips` | trips tab at root | shell, trips tab |
| `/trips/<tripId>` | any `TripDetailScreen` push | trips tab + push detail |
| `/trip/<tripId>` | never written (MCP alias) | same; URL self-normalizes |
| `/alerts` `/preferences` `/account` `/admin/metrics` `/admin/local` `/guides` `/notifications` | utility screens | shell, home tab + push |
| `/import` | import screen | shell, trips tab + push |
| `/share` `/invite` `/reset` `/verify` `/sso` `/connect` | — | UNCHANGED bare boot |

`BootTarget { tab, tripId?, chatId?, utility? }` + `parseBootTarget(Uri)` +
format helpers, used by both halves so they cannot drift. Deliberately
unnamed (URL stays at nearest named ancestor): `TripMapScreen` (closures,
root push), `LocalGuideDetailScreen` (full object), `FlightSearchScreen`
(non-URL-encodable prefill), `AuthScreen`, retake-quiz.

## Flutter Changes

- **New `lib/navigation/app_routes.dart`** — grammar above.
- **New `lib/navigation/url_sync.dart`** — `UrlSyncController` (per-tab stacks
  of named `Route` references; tab-root didPush clears its tab's stack —
  self-healing across GlobalKey remounts; `_shellAttached` gate so bare-boot
  flows never get their URL touched; consume-once boot target; bounded
  retry-push), `TabUrlObserver` (fresh instances per `AppShell.build` — an
  observer can't attach to two navigators), `RootUrlObserver` (post-frame
  re-assert after root nav events — converges over the framework's `/`
  auto-reports), `urlReporterProvider` seam.
- **`lib/main.dart`** — `navigatorObservers`; `generateInitialRoutes` passes
  `isBoot: true`; `generateRoute` parses `BootTarget` → `AuthGate(bootTarget:)`
  (only the boot route carries one — runtime `pushNamed('/')` resets can't
  clobber a flow's chosen tab); delete the bare `/trip/<id>` + `/alerts`
  branches (they boot in-shell now); `AuthGate` → `ConsumerStatefulWidget`
  registering the target with the controller.
- **`lib/screens/app_shell.dart`** — `_TabNavigator` gains `observers`.
- **`lib/navigation/app_nav.dart`** — `locatedRoute(page, location)` +
  `pushOnActiveTab(..., {String? location})`.
- **Named push sites** — trips_list (detail, import), home (2× detail,
  guides), agent (detail), import_trip (pushReplacement detail),
  add_to_trip_sheet, shared_trip (retry-push detail), account_menu (5 utility
  screens), alerts (notifications). **`trip_detail_screen.dart` untouched**
  (hub file; its two pushes stay unnamed by design).
- **Phase B (chat resume)** — `PlanState.chatId` (mirrors `savedTripId`);
  new `lib/providers/plan_resume.dart` `resumePlanChat(...)` lifted from
  `ContinueChatCard._resume`; `continue_chats_section.dart` refactors onto it;
  `/plan/<chatId>` boot calls it, silent degrade to fresh `/plan` (zero new
  l10n strings).

## Go API Changes

None. (The `/trips/<uuid>` re-engagement email links start working purely
client-side.)

## Contract Parity

n/a — no new JSON contract; the chat-resume path reuses the existing
`GET /api/v1/chats/{chatId}` transcript shape.

## Cross-cutting

- No new env vars, no gateway changes, no migrations, no ARB/l10n changes.
- Accepted cosmetics/limitations (documented in spec): brief `/trips` →
  `/trips/<id>` URL settle on deep-link boot; query strings dropped; SSO
  redirect loses the deep-link target.

## Verification

- `make flutter-analyze` && `make flutter-test`.
- New/extended tests: `app_routes_test` (grammar round-trip),
  `deep_link_initial_routes_test` (one-route invariant for every new path),
  `url_boot_restore_test` (real app boot via `defaultRouteNameTestValue`:
  trips detail, alias normalization, in-shell alerts/import, signed-out →
  sign-in lands on target), `url_sync_report_test` (tab/push/pop/unnamed/
  sign-out reporting), `url_plan_chat_test` (resume, reset, boot happy path,
  fetch-failure degrade).
- Manual walk of every spec acceptance criterion on the lane dev stack
  (`make docker-dev-bg`, this lane's gateway), including refresh on each
  surface and the untouched `/share` + `/sso` flows.
