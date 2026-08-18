# Tasks: Landing Page Redesign

> Dependency-ordered. This lane is PR 1; `specs/landing-prompt-handoff/` is
> PR 2 and stacks on it.

## l10n

- [ ] ARB edits (en+es): delete `landingHeroTagline`,
      `landingFeatureAgentTitle`, `landingFeatureAgentDescription`; add the
      new landing keys (hero, prompt, 6 feature pairs, destinations, how,
      CTA)
- [ ] Host `flutter pub get` in `src/packages/flutter-app`, then
      `make flutter-gen-l10n`; verify diff scoped to `lib/l10n/`

## Theme

- [ ] `lib/theme/app_colors.dart`: `landingCanvas`, `landingCard`,
      `landingHairline`, `landingHeroBlend`

## UI (bottom-up; each compiles standalone)

- [ ] `lib/screens/landing/landing_layout.dart`
- [ ] [P] `landing_footer.dart` (promote today's `_LandingFooter`)
- [ ] [P] `landing_section_title.dart`
- [ ] [P] `landing_cta_band.dart`
- [ ] [P] `landing_how_it_works.dart`
- [ ] [P] `landing_feature_grid.dart`
- [ ] [P] `landing_destination_rail.dart`
- [ ] `landing_handoff.dart` (default = today's `_openAuth`, TODO → sibling
      spec)
- [ ] `landing_hero.dart` (photo stack + headline + prompt field + chips)
- [ ] Rewrite `lib/screens/landing_screen.dart` composition (keep analytics
      guard + `_openAuth` verbatim; `Theme(dark)` wrap + `landingCanvas`)

## Tests

- [ ] Rewrite `test/landing_polish_test.dart`: 320×568 fold (field + submit
      above fold, Sign in in bar), es 360×690, desktop 1200×900 widths,
      chips prefill (handoff NOT called), submit → handoff with trimmed
      text / disabled empty, rail card → handoff, all sections present

## Verification

- [ ] `make flutter-analyze` clean
- [ ] `make flutter-test` pass
- [ ] Browser QA: 320/768/1440; dark + light OS theme (page stays dark);
      Spanish; Konami bar tap; legal links; `landing_viewed` once per session

## Lanes

| Lane | Branch | Tasks | Migration # | Registry tail? | ARB key prefix | trip_detail? | Depends on |
|------|--------|-------|-------------|----------------|----------------|--------------|------------|
| UI | `landing-redesign` | all above | — | no | `landing*` | no | — |
| Handoff | `landing-prompt-handoff` | see sibling spec | — | no | — (no new keys) | no | UI (seam + screen) |

**Conflict manifest** — UI lane edits: `landing_screen.dart`,
`app_colors.dart`, `app_en.arb`/`app_es.arb` (+ regen), `landing_polish_test.dart`.
Handoff lane edits: `landing_handoff.dart`, `main.dart`, `url_sync.dart`,
`chat_panel.dart`, `analytics_api_service.dart`, Go analytics files.

**Merge order** — UI → Handoff.
