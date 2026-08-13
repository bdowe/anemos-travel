# Tasks: What to wear & pack

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.

## Derivation (Flutter util)

- [x] `lib/utils/clothing_recs.dart`: `RainLevel`/`rainLevel()`, `TempBand`,
      `ClothingRec`, `clothingRec()`, `clothingSummary()` (constants + header
      cross-reference to `trip_review.go:627-633`)
- [x] `test/clothing_recs_test.dart`: band/rain/swing edges, median-outlier,
      any-day rules, envelope, empty → null, historical, glyph-threshold pins

## l10n

- [x] [P] 12 `wear*` keys in `app_en.arb` + `app_es.arb`
- [x] Run `flutter gen-l10n` (generated files committed; untranslated file
      stays empty)

## UI (Flutter)

- [x] [P] `lib/widgets/wear_recs.dart` (`WearRecsList` + phrase-suppression
      rules)
- [x] `trip_detail_screen.dart`: `_legClothingRecs()` helper; rewire
      `_packingSectionRow` (gate, title, summary, pill, merged child);
      refactor `_weatherGlyph` onto `rainLevel()`
- [x] `test/trip_detail_wear_section_test.dart` (6 cases incl. read-only +
      historical + weather-empty)
- [x] Update `test/trip_detail_fix_actions_test.dart` title expectation

## Verification

- [x] `make flutter-analyze` clean
- [x] `make flutter-test` — full suite (762 passing), not just new tests
- [ ] Manual end-to-end via this lane's gateway (`make docker-dev` →
      http://localhost:3001): every acceptance criterion in `spec.md`
- [ ] `ship pr` (lane stops at PR-open; integrator merges)

## Amendment 2026-08-13 — app-bar icon + sheet

- [x] `lib/widgets/wear_pack_sheet.dart`: `showWearPackSheet` shell (560px
      cap, 0.8 height, keyboard-inset padding, no Scaffold) +
      `WearPackSheetBody` (header title · summary · pill; rows; live
      checklist)
- [x] `checklist_section.dart`: `isOffline` bool → live callback
- [x] `trip_detail_screen.dart`: `_wearAppBarAction` next to health; cluster
      scaffolding + row + visibility gate deleted; 96px FAB spacer keeps the
      `!_inBudgetView` gate (Budget pads its own)
- [x] Tests: wear-section file reworked to tooltip finders + sheet scoping;
      new Escape / breakpoints / live-pill / Budget-view cases; fix-actions
      layout contract; checklist callback call site
- [x] Spec + friction log amended

## Verification (2026-08-13)

- [x] `make flutter-analyze` clean (3 pre-existing route_response infos only)
- [x] Affected test files green (64 tests)
- [x] `make flutter-test` full suite (933 passing; sticky-headers offsets
      retuned for the 8px tail-extent change)
- [x] Manual via this lane's gateway (http://localhost:3011): icon next to
      health, sheet content, add-item with keyboard, live pill, Escape,
      Budget view, viewer gating
- [ ] `ship pr` (lane stops at PR-open; integrator merges — NOTE: PR #356
      also touches the trip-detail app bar; hub-file resolve expected)
