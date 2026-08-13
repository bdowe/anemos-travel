# Plan: Dark Mode

> **HOW.** See `spec.md` for what & why. All paths under
> `src/packages/flutter-app/` unless noted. No Go API changes.

## Technical Approach

`AppTheme._build(Brightness)` was already brightness-parameterized, so the
dark `ThemeData` is `_build(Brightness.dark)` plus two explicit conditionals
for the values that were light-only. A new `themeModeProvider` (structural
mirror of `localeProvider`) stores the three-state choice in
`shared_preferences` and `MaterialApp` watches it for
`theme:`/`darkTheme:`/`themeMode:`. The settings UI is an "Appearance" radio
section modeled 1:1 on the Language picker.

### Decision records

- **Live `ThemeMode.system` — deliberate divergence from locale's
  resolve-once-and-store design.** Locale must resolve to one concrete
  language because the server states it on every request (`Accept-Language`)
  and renders emails from it. Theme has **no server consumer**, so "follow the
  system" can stay a live mode: `MaterialApp.themeMode` tracks OS appearance
  changes natively. Consequently `load()` has **no write-back** (there is
  nothing to resolve) and there is **no `syncToAccount`** (nothing
  server-rendered to keep consistent).
- **First-frame flash accepted.** A user who forces the opposite of their OS
  gets ≤1–2 frames of the wrong brightness while the stored choice loads.
  Blocking `runApp` on storage would penalize every launch to fix a rare
  cosmetic blip; the boot splash (brand teal in both modes) covers the window.
  Locale makes the same call.
- **Card separation in dark = explicit tonal step, not shadow, not M3 tint.**
  The light theme's "light from above" drop shadow is invisible on a dark
  background. Dark cards take `surfaceContainerHigh` as an explicit color
  step; `surfaceTintColor` stays `transparent` in **both** modes so elevation
  never shifts card color implicitly.
- **Token contract (executed in the follow-up `dark-mode-tokens` lane):** on
  `AppColors`, `static final` will mean brightness-independent by definition
  (over photos / satellite / the fixed brand gradient); anything rendered on a
  theme surface becomes a `static Color name(ColorScheme scheme)` method
  (generalizing the existing `forCategory` precedent). Until that lane lands,
  dark mode ships with the static (light-tuned) accents — legible, just not
  contrast-tuned.
- **Marker-cache constraint:** `trip_map.dart`'s cluster-marker cache is keyed
  without brightness. Pin colors must not become theme-derived unless
  brightness joins the cache key (the `dark-mode-tokens` lane does both
  together).
- **The ~75 raw `Colors.white`/`black` literals over `brandGradient` / hero
  scrims / photo scrims / the satellite map are correct in both modes and must
  not be "fixed":** those surfaces are brightness-constant by design, and
  their contrast was validated against the gradient once.

## Flutter Changes

- **Provider** — new `lib/providers/theme_mode_provider.dart`:
  `ThemeModeState { ThemeMode mode; bool loaded; }`, storage key
  `theme_mode` ∈ `'system' | 'light' | 'dark'` (explicit strings, not enum
  indices). Lifecycle mirrors `locale_provider.dart`: constructor renders
  immediately with `ThemeMode.system`; `load()` reads the key in try/catch
  (web private-browsing safe) and sets `loaded`; `setMode()` sets state first,
  then persists in try/catch. Unknown stored values parse to `system` — never
  guess a brightness.
- **Theme** — `lib/theme/app_theme.dart`: add `static ThemeData get dark`;
  seed from `AppColors.brand` (removes the duplicated
  `Colors.teal.shade700`); `isDark` conditionals for
  `inputDecorationTheme.fillColor` (`surfaceContainerHighest` in dark vs
  `Colors.grey[50]`) and the `cardTheme` recipe (see decision record).
- **Wiring** — `lib/main.dart`: watch
  `themeModeProvider.select((s) => s.mode)` alongside the locale watch; pass
  `theme: AppTheme.light, darkTheme: AppTheme.dark, themeMode:`.
- **Settings UI** — `lib/screens/account_settings_screen.dart`: new private
  `_AppearancePicker` (modeled on `_LanguagePicker`: `RadioGroup<ThemeMode>` +
  three `RadioListTile`s) under a `SectionHeader` directly above the Language
  section.
- **l10n** — 4 keys ×2 ARBs (`appearanceSectionTitle`, `appearanceSystem`,
  `appearanceLight`, `appearanceDark`), then `flutter gen-l10n` (generated
  files committed).
- **Web chrome** — `web/index.html`: add the
  `media="(prefers-color-scheme: dark)"` `theme-color` meta (`#004D40`)
  beside the existing `#00695C` one. Splash and `manifest.json` untouched
  (brand-teal, brightness-neutral).
- **Test harness** — `test/support/l10n_test_app.dart` gains an optional
  `ThemeData? theme` pass-through (null default keeps all existing tests
  byte-identical in behavior).

## Contract Parity

No API surface — table intentionally empty.

## Cross-cutting

- No env vars, no gateway changes, no migrations, no registry changes.

## Verification

- `make flutter-analyze` clean; `make flutter-test` green.
- New tests: `test/theme_mode_provider_test.dart` (default / restore /
  garbage-fallback / persist / re-launch), `test/appearance_picker_test.dart`
  (tapping Dark flips `Theme.of` brightness and persists; System follows the
  platform brightness), `test/app_theme_dark_test.dart` (dark scheme
  brightness + the two light/dark divergence pins).
- Manual via `make docker-dev` (this lane's gateway): walk every acceptance
  criterion in `spec.md`, both languages, plus a dark walkthrough of
  Home / Trips / Trip detail / Chat / Settings / Notifications.
