# Plan: iOS App Store v1

> **HOW.** Full audit + program roadmap: the approved plan of 2026-08-13
> (3-agent audit; Apple-side program in Workstream A there is Brian-side and
> not repeated here). Repo conventions: see `../../CLAUDE.md` and
> `../../docs/parallel-dev.md`.

## Technical Approach

Five lanes over two waves. The through-line, per `docs/zen.md`: every place
the web app *implied* its identity from the browser page (origin from
`Uri.base`, SSO return via same-tab navigation, deep links via the URL bar)
gets an **explicit** replacement (a `PUBLIC_BASE_URL` define, a server-chosen
callback scheme, OS-delivered links normalized into the existing router).
Web behavior stays byte-identical — the proof is that no web build config
changes.

Key decisions:

1. **SSO return leg: in-app web-auth session (`flutter_web_auth_2`), not
   native SSO plugins.** Reuses the entire server flow + `SsoCallbackScreen`
   + `POST /auth/sso/exchange` unchanged; guideline 4.8 is satisfied by
   offering Sign in with Apple (Hide My Email works through the web flow).
   Native `sign_in_with_apple` sheet is a documented fast-follow only if
   review objects; nuclear fallback: hide Google on iOS.
2. **`platform=ios` is a server-validated enum, not a redirect URL.** The
   callback scheme `goldentempo://` is hardcoded server-side — the platform
   param can never become an open redirect. Anything outside `{"", "ios"}`
   is a 400.
3. **Universal links feed the existing router.** `app_links` (uni_links is
   deprecated) delivers URIs; a pure normalizer maps them to the same route
   strings the web engine produces; `generateInitialRoutes` /
   `parseBootTarget` are untouched (one grammar, N sources).
4. **Build identity:** marketing version `1.0.0` via `--build-name`; build
   number `git rev-list --count HEAD` (monotonic, 1:1 with main commits);
   uploads tagged `ios/1.0.0+<N>`. pubspec and the web SHA release identity
   untouched.
5. **CI: unsigned compile canary only** (dispatch + weekly macOS job). v1
   uploads are local `make flutter-build-ipa` + Transporter.

## Go API Changes

`src/packages/api/`:

- **`google_auth_handler.go`** — `googleStartHandler`: read `platform`,
  reject ∉ {"", "ios"}; state cookie value becomes
  `state + "." + verifier + "." + platform` (parse with `SplitN(…, ".", 3)`,
  tolerating the legacy 2-field form during the deploy window).
  `googleCallbackHandler`: success and error redirects go through a new
  shared `ssoFinishURL(platform, codeOrError)` → `goldentempo://sso/<…>` for
  ios, `publicAppURL("sso/", …)` otherwise.
- **`apple_auth_handler.go`** — same, cookie gains a platform field (today
  bare state); the 303-after-form_post to a custom scheme is intercepted
  fine by the auth session. Also: persist the Apple refresh token on every
  successful sign-in (latest wins).
- **`apple_oauth.go`** — `exchangeAppleCode` (~line 171) currently keeps only
  `id_token`; also capture `refresh_token`. New `revokeAppleToken(ctx, token)`
  posting `client_id` + ES256 client secret + `token` +
  `token_type_hint=refresh_token` to `APPLE_REVOKE_URL` (default
  `https://appleid.apple.com/auth/revoke`; env seam = fake-Apple test route).
- **`account_handler.go`** — `deleteAccountHandler` (~line 161): before
  `DeleteUser`, if the user has an apple identity with a stored refresh
  token, call `revokeAppleToken`; log-and-continue on failure (explicitly
  silenced, per zen: deletion must never depend on Apple availability).
- **`auth_handler.go`** — `UserResponse` gains `has_password bool` populated
  via the existing `hasPassword(u)`.
- **Migration `<next>_apple_refresh_token.sql`** — take the next free number
  at lane time (`ls src/packages/api/migrations | tail -1`); **00058 is
  permanently burned** and must never be used (`docs/parallel-dev.md` §4a):
  `ALTER TABLE auth_identities ADD COLUMN refresh_token text;` (nullable).
- **`query/auth_identities.sql`** — add `SetAuthIdentityRefreshToken` +
  `GetAuthIdentityForUserByProvider`; `make api-sqlc`.
- **Routes:** none added or changed in `main.go`.

## Flutter Changes

`src/packages/flutter-app/`:

- **`lib/constants/public_origin.dart` (new)** — `PUBLIC_BASE_URL` define;
  resolution: define wins → else the page's own origin (web) → else `''` +
  debug assert (a native build missing the define dies on first
  `flutter run`). Pure `resolvePublicOrigin(...)` core for tests.
  Converted call sites: `lib/utils/share_link.dart` (`shareUrl`, `_exportUrl`),
  `lib/widgets/legal_links.dart` (localhost fallback deleted), both SSO
  buttons; `lib/screens/connect_app_screen.dart:81` gains
  `LaunchMode.externalApplication` off-web.
- **`lib/services/sso_web_auth.dart` (new)** — thin provider seam over
  `FlutterWebAuth2.authenticate(url: '$base/auth/<p>?platform=ios',
  callbackUrlScheme: 'goldentempo')` so button widget tests fake it. Buttons:
  web path unchanged; native path pushes `/sso/<code>` so `SsoCallbackScreen`
  does exchange/adopt exactly as web. Cancellation swallowed.
- **`lib/navigation/incoming_links.dart` (new)** — pure
  `normalizeIncomingLink(Uri)`:
  `https://goldentempotravel.com/app/<rest>` → `/<rest>`;
  `goldentempo://sso/<c>` → `/sso/<c>`; else null. Cold start:
  `AppLinks().getInitialLink()` → `MaterialApp.initialRoute` (null on web).
  Warm: `uriLinkStream` pushes token routes
  (`share|invite|reset|verify|sso|connect`) on a new root `navigatorKey`
  (`lib/main.dart`, currently unset). Warm grammar paths ignored in v1
  (documented).
- **`lib/providers/dictation_provider.dart:28`** —
  `fallback: kIsWeb ? RecorderEngine(...) : null` (the recorder engine is
  web-shaped and hard-fails if ever selected on iOS).
- **User model** — add `hasPassword` with `@JsonKey(name: 'has_password',
  defaultValue: false)`; `make flutter-build-models`. Default-false rationale
  (zen: worst failure mode chosen explicitly): a stale cached snapshot
  without the field renders the passwordless dialog, and the server still
  enforces password verification — one retriable error, never the blocked
  deletion the old behavior caused.
- **`lib/screens/account_settings_screen.dart`** — `_DeleteAccountDialog`
  (~407–418): password field + non-empty gate only when `hasPassword`;
  otherwise plain confirm with `settingsDeleteSsoBody` copy (en+es).
- **AI disclosure** — one-time pre-first-send notice in the chat composer
  flow (`lib/widgets/chat_panel.dart` + a small new widget), acknowledged
  flag in shared_preferences; arb prefix `chatAiDisclosure*`.
- **iOS shell** (`ios/`): bundle ID `com.goldentempo.travel` everywhere
  (pbxproj ~371/550 + RunnerTests); delete legacy
  `CODE_SIGN_IDENTITY "iPhone Developer"` (~335); `TARGETED_DEVICE_FAMILY=1`
  (~353/479/532); `CODE_SIGN_ENTITLEMENTS` → new `Runner/Runner.entitlements`
  (`applinks:` + `webcredentials:` goldentempotravel.com); `DEVELOPMENT_TEAM`
  left unset with comment (fills post-enrollment). `Info.plist`:
  `NSPhotoLibraryUsageDescription`, `ITSAppUsesNonExemptEncryption=false`,
  `CFBundleLocalizations` [en, es], `CFBundleURLTypes` (`goldentempo`).
  Icons: `flutter_launcher_icons` seeded from `web/icons/Icon-512.png`
  (1024², mark-only), `remove_alpha_ios: true` onto `#00695C`; commit the
  appiconset. `pod install` → commit `ios/Podfile.lock`.
- **New deps:** `flutter_web_auth_2` (L3), `app_links` (L4),
  `flutter_launcher_icons` dev-dep (L1).

## Contract Parity  ← anti-drift gate

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| `has_password` | `bool` (`UserResponse`, `auth_handler.go`) | `bool` (`@JsonKey(defaultValue: false)`) | no (absent → false) | ☐ |

Redirect contract (not JSON, pinned by Go integration tests + Dart widget
tests): `platform=ios` ⇒ callback `Location` is
`goldentempo://sso/<code>` on success and `goldentempo://sso/error` on
failure; empty platform ⇒ byte-identical `publicAppURL("sso/", …)`; any other
platform value ⇒ 400 at start.

## Cross-cutting

- **Env vars:** `APPLE_REVOKE_URL` (test seam, default Apple's real endpoint)
  → `.env.sample`. No other new server config.
- **Dart defines (native builds only):**
  `API_BASE_URL=https://goldentempotravel.com/api/v1`, `APP_BASE_PATH=/app/`,
  `PUBLIC_BASE_URL=https://goldentempotravel.com` — carried exclusively by
  new Makefile targets `flutter-build-ipa` / `flutter-run-ios` (never
  hand-typed). Web builds unchanged.
- **Gateway:** AASA file committed under `dockerize/deployment/nginx/` +
  exact-match location for `/.well-known/apple-app-site-association`
  (`app-locations.conf` reserves the path, ~line 113); JSON content-type, no
  redirect; `appIDs: ["TEAMID.com.goldentempo.travel"]` with `TEAMID`
  placeholder (single post-enrollment edit + redeploy); include
  `webcredentials` block. Verify whether `dockerize/production/nginx` shares
  the snippet.
- **CI:** new `.github/workflows/ios.yml` — `workflow_dispatch` + weekly
  cron, `macos-15`, flutter pinned 3.35.4,
  `flutter build ios --release --no-codesign` with the three prod defines.
  Not wired into the deploy chain.

## Verification

(Mirrored into `tasks.md`; per-lane detail lives there.)

- Go: extend `google_auth_integration_test.go` /
  `apple_auth_integration_test.go` (fake seams exist) for the platform
  matrix; fake-Apple gains an `/auth/revoke` recorder; delete-account
  matrix (apple user → exactly 1 revoke + 204; email → 0; revoke-500 →
  deletion still succeeds); `has_password` asserted in login/me payloads.
- Flutter: `test/public_origin_test.dart` pure matrix; share/export/legal
  URL tests in the VM env (where `Uri.base` is `file:` — exactly the iOS
  failure mode); `test/incoming_links_test.dart` mirroring every path in
  `deep_link_initial_routes_test.dart` + `/app/`-prefixed + scheme forms,
  re-asserting the single-initial-route invariant; delete-dialog widget test
  both variants; SSO button tests with the faked web-auth seam.
- Device (TestFlight) checklist: email signup + verify link; Google + Apple
  sign-in incl. Hide My Email; share/invite cold+warm; both password-reset
  paths; legal links; photo attach permission prompt; dictation;
  background-mid-stream graceful failure; map/offline/print/.ics; deletion
  for both account kinds (revocation in server log); Spanish locale; dark
  mode.
