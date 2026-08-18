# Plan: Landing Page Redesign

> **HOW.** See `spec.md` for what/why. Sibling spec:
> `specs/landing-prompt-handoff/` owns everything after submit.

## Technical Approach

Rewrite `lib/screens/landing_screen.dart` in place (path kept — imported by
`main.dart` and five tests) as a composition root over new section widgets in
`lib/screens/landing/`. The hero becomes full-bleed edge-to-edge below the
opaque `GradientAppBar` (no `extendBodyBehindAppBar` — the bar's gradient ends
on `brandDark`, exactly where the hero scrim starts, so they already read as
one field) and carries a real prompt input. The whole route is wrapped in
`Theme(data: AppTheme.dark)` with `Scaffold(backgroundColor:
AppColors.landingCanvas)` — committed dark for this route only, zero contact
with the MaterialApp theme plumbing. Sections each apply their own
`PageContainer`; the marketing content tier is `kLandingContentWidth = 1080`.

Key decisions:
- **No in-hero logo/wordmark** — the app bar already carries the lockup on the
  landing page ("the brand *is* the title"); the current page brands three
  times, and dropping it frees ~140px for the 320×568 fold contract. Also
  keeps the konami rule trivially true (no hero logo to mis-wire).
- **Chips prefill, cards submit** — hero chips are suggestions (fill + focus);
  destination-rail cards are commitments (straight into the handoff), matching
  how the home hero chips send but keeping the landing's first submit an
  explicit user act in the field OR an explicit card choice.
- **Feature cards are plain `Container`s, not `Card`** — the dark `cardTheme`
  fill is a neutral grey (`surfaceContainerHigh`) that fights the teal canvas;
  the landing family tokens (below) keep the grid glassy. Monochrome white
  icons (the `tool*` accents are shade600/700 values tuned for paper and go
  muddy on deep teal; if color returns later, the precedent is a
  per-brightness mapping like `AppColors.upMark`).
- **Rail reuses `DestinationSuggestionCard` + the `suggestionPool`** — the
  CC BY credit overlay, `cacheWidth` bounding, and localized
  label-is-what-gets-sent contract come for free. Deliberately NOT
  `DestinationSuggestionCarousel` (no timer/auto-advance = no `pumpAndSettle`
  hazards); a lazy horizontal `ListView` with the next card peeking.
- **Handoff seam**: `lib/screens/landing/landing_handoff.dart` exposes
  `landingPromptHandoffProvider` (`void Function(BuildContext, String text,
  {String? sourceId})`). This lane ships a default that degrades to today's
  behavior (`_openAuth` sign-up; prompt dropped, TODO naming the sibling
  spec). Widget tests override it to record calls.

## Go API Changes

None.

## Flutter Changes

`src/packages/flutter-app/`:

- `lib/screens/landing_screen.dart` — rewritten composition root. Keeps
  verbatim: the `landing_viewed` once-per-session guard, `_openAuth`, the
  `GradientAppBar` actions (globe + Sign in).
- NEW `lib/screens/landing/`:
  - `landing_layout.dart` — `kLandingContentWidth = 1080`, section rhythm.
  - `landing_hero.dart` — `LandingHero` (photo/scrim/blend stack, headline,
    subtitle, prompt field + chips, have-account link). Local `narrow < 600`.
  - `landing_feature_grid.dart` — `LandingFeatureGrid` (6 features, 1/2/3
    columns via `Wrap` at <560/<900/≥900).
  - `landing_destination_rail.dart` — `LandingDestinationRail`
    (`RandomSuggestions(picker: suggestionOrderProvider)` → horizontal
    `ListView.separated` of `DestinationSuggestionCard`s, mouse-drag enabled).
  - `landing_how_it_works.dart` — 3 numbered steps, Row ≥900 / stacked below.
  - `landing_cta_band.dart` — brandGradient card in `PageContainer(700)`.
  - `landing_footer.dart` — today's footer, promoted.
  - `landing_section_title.dart` — Marcellus centered white section heading
    (marketing register; `SectionHeader` stays the app's utilitarian one).
  - `landing_handoff.dart` — the provider seam (above).
- `lib/theme/app_colors.dart` — the landing dark-canvas family only:
  `landingCanvas` (lerp brandDark→black 0.55), `landingCard` (white 6%),
  `landingHairline` (white 14%), `landingHeroBlend` (transparent→canvas).
- ARBs: remove `landingHeroTagline`, `landingFeatureAgent{Title,Description}`;
  add hero/feature/rail/how/CTA keys (en+es). Regen: host `flutter pub get`
  in `src/packages/flutter-app` FIRST (Docker rewrites
  `.dart_tool/package_config.json`; gen-l10n's format step crashes after
  writing files — docs/friction-log.md), then `make flutter-gen-l10n`; diff
  must stay scoped to `lib/l10n/`.

## Contract Parity

No Go↔Flutter contract changes in this lane.

## Cross-cutting

- New Material icons change the tree-shaken `MaterialIcons-Regular.otf` on
  deploy — covered by the `no-cache` + edge-parity machinery; expected diff,
  no action.
- No pubspec/asset changes; both image directories are already declared.

## Verification

- `make flutter-analyze` and `make flutter-test` clean.
- Rewritten `test/landing_polish_test.dart` (fold contract, es, desktop
  widths, chips-prefill, submit-calls-handoff, rail-seeds-handoff, section
  presence). Ahem-safe: positions/presence only.
- Browser QA at 320/768/1440, dark AND light OS theme (page stays dark),
  Spanish via the globe, Konami bar tap, `landing_viewed` in admin metrics.
