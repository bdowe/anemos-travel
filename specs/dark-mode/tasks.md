# Tasks: Dark Mode

> Dependency-ordered. Verification is last.

## UI (Flutter)

- [x] Add `lib/providers/theme_mode_provider.dart` (mirror of locale_provider)
- [x] `lib/theme/app_theme.dart`: `dark` getter, seed from `AppColors.brand`,
      input-fill + card-recipe conditionals
- [x] `lib/main.dart`: `darkTheme:` + `themeMode:` wiring
- [x] `_AppearancePicker` section in `account_settings_screen.dart`
- [x] 4 ARB keys ×2 + `flutter gen-l10n` (commit generated files)
- [x] `web/index.html` dark `theme-color` meta
- [x] `test/support/l10n_test_app.dart` optional `theme` param

## Verification

- [x] New tests: provider persistence, appearance picker, dark theme pins
- [x] `make flutter-analyze` clean (3 pre-existing infos in route_response.dart only)
- [x] `make flutter-test` pass (886 tests)
- [x] Manual end-to-end via this lane's gateway (headless Chrome, SSO-handoff
      login): System default follows a live OS dark flip; forced Light pins
      against a dark platform; forced Dark persists through reload
      (localStorage `flutter.theme_mode`); Home/Trips/Plan/Account render the
      seeded dark scheme (pixel-verified surface #0E1513)

## Follow-up (separate lane: `dark-mode-tokens`)

- [ ] AppColors static-vs-`(ColorScheme)` token contract + dark tuning
      (semantic pairs, tool accents, shadows, point fixes, health_pane
      de-dupe, contrast guard test) — see plan.md decision records
