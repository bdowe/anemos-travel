# Tasks: iOS App Store v1

> Dependency-ordered. `[P]` = parallel-safe. Lanes below; Brian-side
> (enrollment/store) items live in the approved roadmap, not here — except
> where a code task blocks on them (marked ⏳ enrollment).

## L1 `ios-scaffold`

- [ ] pbxproj: bundle ID → `com.goldentempo.travel` (all configs incl.
      RunnerTests); delete legacy `CODE_SIGN_IDENTITY`; `TARGETED_DEVICE_FAMILY=1`;
      `CODE_SIGN_ENTITLEMENTS`; `DEVELOPMENT_TEAM` unset + comment
- [ ] New `ios/Runner/Runner.entitlements` (applinks + webcredentials)
- [ ] Info.plist: `NSPhotoLibraryUsageDescription`,
      `ITSAppUsesNonExemptEncryption=false`, `CFBundleLocalizations` [en, es],
      `CFBundleURLTypes` (`goldentempo` scheme)
- [x] Icons: DONE early by the Phase-B brand lane (PR #374, 2026-08-13):
      `flutter_launcher_icons` dev-dep seeded from `web/icons/Icon-maskable-512.png`
      (wind rose on WHITE — the planned `#00695C` background was dropped
      because the new rose is teal-on-teal against it), appiconset committed
- [ ] `dictation_provider.dart`: `fallback: kIsWeb ? RecorderEngine(...) : null`
      + widget test (no fallback engine off-web)
- [ ] `pod install` → commit `ios/Podfile.lock` (host needs CocoaPods installed)
- [ ] New `.github/workflows/ios.yml` (dispatch + weekly, macos-15, 3.35.4,
      `flutter build ios --release --no-codesign`, prod defines); one dispatch run
- [ ] Local `flutter build ios --release --no-codesign` succeeds

## L2 `ios-public-origin`

- [ ] New `lib/constants/public_origin.dart` (define → web origin → '' +
      debug assert; pure `resolvePublicOrigin`)
- [ ] Convert `share_link.dart` (`shareUrl`, `_exportUrl`), `legal_links.dart`
      (delete localhost fallback), `connect_app_screen.dart`
      (`LaunchMode.externalApplication` off-web)
- [ ] Makefile: `flutter-build-ipa` (3 prod defines + `--build-name=1.0.0`
      `--build-number=$$(git rev-list --count HEAD)`), `flutter-run-ios`
      (dev-gateway defines)
- [ ] `test/public_origin_test.dart` matrix + share/export/legal URL tests in
      the VM env (Uri.base = file:)
- [ ] Web parity: zero diffs to web build configs (Dockerfiles, ci.yml,
      `make flutter-build-web`)

## L3 `sso-native-return`

- [ ] `google_auth_handler.go`: `platform` param (400 unless ∈ {"", "ios"}),
      3-field state cookie (tolerate legacy 2-field), `ssoFinishURL` helper
- [ ] `apple_auth_handler.go`: same (cookie gains platform field)
- [ ] Go integration tests: platform matrix (ios → `goldentempo://sso/<code>`
      / `goldentempo://sso/error`; empty → byte-identical; other → 400)
- [ ] New `lib/services/sso_web_auth.dart` seam + `flutter_web_auth_2` dep
- [ ] Both sign-in buttons: web unchanged; native → auth session → push
      `/sso/<code>`; cancellation silent; widget tests with faked seam
- [ ] One-time AI-processing disclosure before first chat send
      (`chat_panel.dart` + small widget, shared_preferences flag,
      `chatAiDisclosure*` arbs en+es) + widget test

## L4 `universal-links` (wave 2)

- [ ] `app_links` dep; new `lib/navigation/incoming_links.dart`
      (`normalizeIncomingLink` pure fn)
- [ ] `lib/main.dart`: cold-start initial route (native only) + root
      `navigatorKey` + warm-link subscription (token routes only)
- [ ] `test/incoming_links_test.dart`: normalization matrix mirroring
      `deep_link_initial_routes_test.dart` + `/app/` + scheme forms;
      single-initial-route invariant re-asserted
- [ ] AASA file under `dockerize/deployment/nginx/` + exact-match
      `/.well-known/apple-app-site-association` location (JSON content-type);
      `TEAMID` placeholder; webcredentials block; check
      `dockerize/production/nginx` snippet sharing
- [ ] ⏳ enrollment: fill real `TEAMID` → deploy → `curl` AASA + on-device
      link-open verification

## L5 `apple-revoke-delete-ux` (wave 2)

- [ ] Migration `<next free>_apple_refresh_token.sql` (nullable `refresh_token`
      on `auth_identities`) — **not 00058, that number is burned**; take the
      next number above main's highest; queries `SetAuthIdentityRefreshToken` +
      `GetAuthIdentityForUserByProvider`; `make api-sqlc`
- [ ] `apple_oauth.go`: capture `refresh_token` in `exchangeAppleCode`;
      `revokeAppleToken` + `APPLE_REVOKE_URL` seam (→ `.env.sample`)
- [ ] `apple_auth_handler.go`: persist refresh token on sign-in (latest wins)
- [ ] `account_handler.go`: revoke-before-delete for apple identities,
      log-and-continue on failure
- [ ] Go tests: fake-Apple `/auth/revoke` recorder; apple delete → 1 revoke +
      204; email delete → 0; revoke-500 → delete succeeds; `has_password` in
      login/me payloads
- [ ] `UserResponse.has_password` + Dart user model
      (`@JsonKey(defaultValue: false)`) + `make flutter-build-models`;
      parity row ✓ in `plan.md`
- [ ] `_DeleteAccountDialog`: password gate only when `hasPassword`; plain
      confirm + `settingsDeleteSso*` copy (en+es); widget test both variants

## Verification (workstream close-out)

- [ ] `make api-fmt && make api-vet && make api-test` clean
- [ ] `make flutter-analyze && make flutter-test` clean (l10n coverage gate)
- [ ] Manual web pass via `make docker-dev`: sign-in, share, legal links,
      delete dialog (both account kinds) — proves web parity
- [ ] Device checklist (TestFlight, post-enrollment): every acceptance
      criterion in `spec.md` on a physical iPhone (list in `plan.md`
      §Verification)

## Lanes

| Lane | Branch | Tasks | Migration # | Registry tail? | ARB key prefix | trip_detail? | Depends on |
|------|--------|-------|-------------|----------------|----------------|--------------|------------|
| L1 | `ios-scaffold` | L1 block | — | no | — | no | — |
| L2 | `ios-public-origin` | L2 block | — | no | — | no | — |
| L3 | `sso-native-return` | L3 block | — | no | `chatAiDisclosure` | no | — |
| L4 | `universal-links` | L4 block | — | no | — | no | L1 (scheme/entitlements settled) |
| L5 | `apple-revoke-delete-ux` | L5 block | **next free** (NOT 00058 — burned) | no | `settingsDeleteSso` | no | L3 (`apple_auth_handler.go`) |

**Conflict manifest** (existing files edited per lane; new files free):

- L1: `ios/Runner.xcodeproj/project.pbxproj`, `ios/Runner/Info.plist`,
  `ios/Podfile`, `pubspec.yaml` (dev-dep), `lib/providers/dictation_provider.dart`
- L2: `lib/utils/share_link.dart`, `lib/widgets/legal_links.dart`,
  `lib/screens/connect_app_screen.dart`, `Makefile`
- L3: `src/packages/api/google_auth_handler.go`,
  `src/packages/api/apple_auth_handler.go`,
  `lib/widgets/google_sign_in_button.dart`,
  `lib/widgets/apple_sign_in_button.dart`, `lib/widgets/chat_panel.dart`,
  `pubspec.yaml`, arbs
- L4: `lib/main.dart`, `pubspec.yaml`,
  `dockerize/deployment/nginx/snippets/app-locations.conf`
- L5: `src/packages/api/apple_oauth.go`,
  `src/packages/api/apple_auth_handler.go`,
  `src/packages/api/account_handler.go`, `src/packages/api/auth_handler.go`,
  `src/packages/api/query/auth_identities.sql`, `.env.sample`, user model +
  `.g.dart` (regen), `lib/screens/account_settings_screen.dart`, arbs

Constraints check: no lane touches `trip_detail_screen.dart` or
`plan_tool_registry.go`; one migration total (L5); ARB prefixes unique;
`pubspec.yaml` is take-both across L1/L3/L4; `ios/Podfile.lock` and `store/`
and `.g.dart` are regen-last (integrator runs `pod install` /
`make api-sqlc` / `make flutter-build-models` after the last relevant merge).

**Merge order:** L1, L2, L3 in any order (wave 1) → L4 after L1, L5 after L3
(wave 2). Lane agents stop at PR-open (`ship pr`); integrator merges
(`/integrate`).
