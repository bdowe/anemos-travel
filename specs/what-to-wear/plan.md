# Plan: What to wear & pack

> **HOW.** Translates `spec.md` into a file-level technical approach. Every
> decision should trace back to an acceptance criterion. See `../../CLAUDE.md`
> for repo conventions referenced below — don't restate them, point to them.

## Technical Approach

Client-only. The screen already fetches a `WeatherReport` per city per leg
window (`weatherByCityProvider`, keyed `WeatherQuery{city,start,end}` with
value equality); a new pure util derives a typed clothing recommendation from
each report, and `_packingSectionRow` composes the recommendations above the
existing `ChecklistSection` inside the same `CollapsibleSection`. Key
decisions:

- **Derivation lives in ONE new pure util** (`lib/utils/clothing_recs.dart`,
  no widget/l10n imports — the `leg_ranges.dart` pattern). The screen's
  `_weatherGlyph` is refactored onto the util's `rainLevel()` in the same
  change so the client has exactly one rain-threshold definition (zen: one
  derivation, N call sites). The Go review constants
  (`trip_review.go:627-633`) are a *different job* (advisory findings) — not
  twinned; the util's header cross-references them, and its extreme-condition
  edges (34°C / 0°C / 60% / 5mm) are deliberately equal so the two surfaces
  can never contradict (spec criterion 8).
- **Range source is `rawLegRanges(trip)` iterated as a list** — the
  doc-pinned weather range source (`leg_ranges.dart:119`). NOT the
  `groupRanges` label map (last-wins for revisited cities) and NOT the
  pending `trip.legs` payload repoint (that lane's plan already treats
  raw-range consumers explicitly; this feature stays in that bucket).
  **Displayed dates are the index-aligned `visibleLegRanges` pair** (1:1 with
  raw by construction) so a row can never disagree with the city-header
  chips — the same raw-vs-visible twin the nights counter rides; only the
  WeatherQuery stays on raw.
- **Fetch sharing, honestly stated**: a single-visit city's WeatherQuery is
  byte-identical to its city-group watch, so the provider family dedups (one
  fetch shared with the chips). A revisited city's earlier visits query
  per-visit windows the chips never build — one extra cached /weather call
  each, the accepted cost of one-row-per-visit.
- **No server phrasing**: the /plan agent already reads raw weather via
  `get_weather` and phrases advice itself; print/export render raw weather
  lines. Nothing server-side wants the band table.
- **Degradation is structural**: `weatherByCityProvider` resolves failures to
  an empty report, so "no recs" is indistinguishable from loading and the
  gate reduces bit-identically to today's behavior offline.

## Go API Changes

**None.** No routes, handlers, services, types, env vars, or migrations.

## Flutter Changes

`src/packages/flutter-app/`:

- **`lib/utils/clothing_recs.dart` (NEW)** — pure derivation:
  - `enum RainLevel { none, some, likely }`;
    `RainLevel rainLevel(WeatherDay d)` — forecast (`precipProbability !=
    null`): ≥60 likely / ≥30 some; historical: `precipMm` ≥5 likely / ≥1
    some. Exactly the current `_weatherGlyph` thresholds.
  - `enum TempBand { freezing, cold, cool, mild, warm, hot }` from the
    **median** of daily highs (one freak day can't flip the band):
    freezing ≤0 · cold 1–7 · cool 8–15 · mild 16–22 · warm 23–29 · hot ≥30.
  - `class ClothingRec { band, rainLikely, bigSwing, extremeHeat,
    freezingNights, historical, loC, hiC }` — flags are any-day rules:
    rainLikely = any `rainLevel == likely`; bigSwing = any `(max-min) ≥ 12`;
    extremeHeat = any `max ≥ 34`; freezingNights = any `min ≤ 0`;
    `loC`/`hiC` = envelope min(min)/max(max), rounded.
  - `ClothingRec? clothingRec(WeatherReport)` (null on empty days);
    `({int loC, int hiC, bool rainLikely}) clothingSummary(List<ClothingRec>)`
    — cross-region envelope for the collapsed line.
- **`lib/widgets/wear_recs.dart` (NEW)** — `WearRecsList`, stateless,
  display-only. Input: precomputed `(label, start, end, rec)` records. Per
  region: muted `Lisbon · Sep 15–20` line (`DateFormat.MMMd`), then the
  phrase: band phrase + flag phrases joined ` · `, italic
  `tripTypicalForDates` appended when historical (the `_weatherChip`
  convention). Suppression: freezingNights hidden when band ∈ {freezing,
  cold}; bigSwing hidden when band ∈ {freezing, cold, cool}; extremeHeat
  hidden when band == hot.
- **`lib/screens/trip_detail_screen.dart`** (hub file, this lane only):
  - New `_legClothingRecs(Trip)` helper: iterate `rawLegRanges(trip)`, skip
    `_kOtherPlaces` and null start/end, watch
    `weatherByCityProvider(WeatherQuery(city: r.label, startDate:
    _fmt(r.start!), endDate: _fmt(r.end!)))` (byte-identical keys to the
    city-group watch → family dedup, one fetch shared with the chips),
    `valueOrNull` → `clothingRec(...)`, collect non-null.
  - `_packingSectionRow` gate becomes:
    `showChecklist = items != null && !(items.isEmpty && _readOnly);`
    `if (!showChecklist && recs.isEmpty) return null;`
  - `CollapsibleSection`: title → `l10n.wearSectionTitle`; summary → recs
    present ? `'${lo}°–${hi}°'` (+ ` · ` + `wearSummaryRain` when rainy,
    kind-neutral, no "typical") : existing `checklistSummary`; checked-count
    moves to `pill: StatusPill.custom('$checked/$total')` when items
    non-empty; child = `Column([if (recs.isNotEmpty) WearRecsList(...),
    ChecklistSection(showHeader: false, ...)])`.
  - `_weatherGlyph` refactored to switch on `rainLevel(day)`.
- **l10n** (`lib/l10n/app_en.arb` + `app_es.arb`, prefix `wear`):
  `wearSectionTitle` "What to wear & pack", `wearBandFreezing`,
  `wearBandCold`, `wearBandCool`, `wearBandMild`, `wearBandWarm`,
  `wearBandHot`, `wearRainLikely`, `wearBigSwing`, `wearExtremeHeat`,
  `wearFreezingNights`, `wearSummaryRain` "rain likely". Temps code-built
  (precedent: the chip's `'$hi° / $lo°'`). Run `flutter gen-l10n`; generated
  files committed, never hand-edited; `l10n_untranslated.json` stays empty.

No models, services, or providers change (no new JSON crosses the wire).

## Contract Parity  ← anti-drift gate

**Empty by design.** No JSON key is added or changed on either side; the
feature is a client display-only derivation from the existing `/weather`
response (precedent: `nightsBetween` — "Client display only — NOT part of the
Go-twin contract", `leg_ranges.dart:227`).

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| *(none — no wire changes)* | — | — | — | ✓ |

## Cross-cutting

- **Env vars:** none.
- **Gateway:** no new paths.
- **Behavior change (accepted):** the parent now fetches weather for every
  dated leg at page open (previously only expanded city groups) — required
  for the collapsed summary; cheap (keyless Open-Meteo, server 3h summary /
  24h geo caches, provider-family dedup with the chips).
- **Known gap flagged:** temps are °C-only app-wide; bands are defined in °C
  constants so a future units preference only touches display.

## Verification

(Mirrored into `tasks.md`.)

- `make flutter-analyze` clean; `make flutter-test` full suite (dated-trip
  tests newly instantiate weather providers — the flutter_test 400-stub is
  caught → empty report → old behavior; confirm nothing timing-strict broke).
- New `test/clothing_recs_test.dart`: band edges both sides (0/1, 7/8, 15/16,
  22/23, 29/30 median high), median-vs-outlier, rain edges (59/60 %,
  4.9/5.0 mm), any-day flag rules, swing 11/12, envelope + rounding,
  empty → null, historical passthrough, `rainLevel` pins of the old glyph
  thresholds, `clothingSummary` merge.
- New `test/trip_detail_wear_section_test.dart` (fakes from
  `trip_detail_weather_test.dart` + `trip_detail_fix_actions_test.dart`):
  collapsed title/summary, expanded rows + checklist + add field, historical
  qualifier, read-only + empty checklist + weather → recs only,
  weather empty → hidden as today.
- Update `test/trip_detail_fix_actions_test.dart:376` title expectation
  (`Packing & prep` → `What to wear & pack`) — the only breaking reference;
  `checklist_section_test.dart` pins the untouched `checklistTitle`, and the
  print packet title is server-side Go i18n.
- Manual via `make docker-dev` (this lane: http://localhost:3001): walk each
  acceptance criterion in `spec.md` (near trip = forecast summary consistent
  with chip umbrella days; far trip = "typical" per row; read-only viewer;
  agent `add_packing_item` + Trip-health one-tap fix land in the merged
  section; print packet unchanged; Spanish spot-check).

## Amendment 2026-08-13 — surface move: app-bar icon + modal sheet

The trailing-cluster row retired; the entry is now an app-bar luggage icon
opening a modal bottom sheet (the Trip health precedent, friction-log
2026-08-13). Design decisions: no count badge on the icon (health's numeric
badge sits next door; the checked/total pill moved into the sheet header);
weather regions are a press-time snapshot passed into the sheet
(`_legClothingRecs` stays the one producer) while the checklist stays live
via its own provider; the old two-tier visibility gate collapsed into the
icon's single Consumer (`_legClothingRecsVisible` deleted); the sheet pads
its scrollable by `viewInsets.bottom` because it hosts the add-item
TextField (the health sheet has no input).

Files: new `lib/widgets/wear_pack_sheet.dart` (`showWearPackSheet` +
`WearPackSheetBody`); `lib/screens/trip_detail_screen.dart`
(`_wearAppBarAction`, cluster scaffolding `_sectionCluster` /
`_expandedSections` / `_packingSectionRow` / `_wearSummary` /
`_legClothingRecsVisible` deleted, packing sliver → plain 96px FAB spacer);
`lib/widgets/checklist_section.dart` (`isOffline` bool → live callback);
tests: `trip_detail_wear_section_test.dart` reworked to the icon/sheet
surface + new cases (Escape, breakpoints, live pill, Budget-view icon),
`trip_detail_fix_actions_test.dart` layout contract, `checklist_section_test.dart`
callback form, `trip_detail_filter_lenses_test.dart` comment.

## Amendment 2026-08-17 — summary first, city detail behind a disclosure

Client-only again; **`trip_detail_screen.dart` is untouched** (`_wearState` /
`_legClothingRecs` already hand the sheet a `List<WearRegionRec>` and
`showWearPackSheet`'s signature is unchanged), so the lane never contended for
the god file.

- **`lib/utils/clothing_recs.dart`** — the derivation stays in one place:
  `enum PackEssential` (declaration order IS render order — nothing sorts, so
  Dart's sub-32 insertion-sort fallback can't make an ordering test vacuous),
  `essentialsFor(TempBand, Set<WearAdvisory>)` mapping each rendered phrase to
  the objects it asks for, `typedef PackItem`, and `packEssentials(regions)`
  built by iterating **`groupWearRegions`** — the exact list `WearRecsList`
  renders. That is what makes the collapse lossless, and it is pinned by a
  test asserting set-equality between the summary and the union over the
  groups. `PackItem.everyStop` counts contributing GROUPS, not labels: a
  merged run is one stop's worth of guidance however many cities it names.
  `anyHistorical(regions)` hoists the footnote gate out of the widget (equal
  to `groups.any((g) => g.historical)` because groups partition the regions
  and OR the flag).
- **`lib/widgets/wear_recs.dart`** — new `PackEssentialsList` (muted 18px
  leading glyph, object over its attribution). `rainGear`/`sunProtection`
  reuse the day chip's `Icons.umbrella`/`Icons.wb_sunny` so the two surfaces
  share one vocabulary. `WearRecsList` loses its footnote block and is
  otherwise unchanged.
- **`lib/widgets/wear_pack_sheet.dart`** — `WearPackSheetBody` becomes a
  `ConsumerStatefulWidget` owning `_cityDetailOpen` (`CollapsibleSection`
  requires the parent to own `expanded`; route-scoped, and reopening the sheet
  is meant to start closed). Order: header · muted `wearPackTitle` label ·
  `PackEssentialsList` · footnote · disclosure-or-inline rows · divider ·
  checklist. `groupWearRegions(regions).length < 2` renders the rows inline.
  `regions.isEmpty` (the Next Step `add_packing` entry, offline, undated) keeps
  today's checklist-only body verbatim.
- **l10n:** ten `wear*` keys in `app_en.arb` + `app_es.arb`.
- **Tests:** `clothing_recs_test.dart` gains `essentialsFor` (band table,
  per-advisory table, and the idempotence of an advisory that restates its
  band — "bring layers" on a mild leg is the same light layer, one row not
  two), `packEssentials` (union invariant, fixed order under reversal,
  attribution + revisit dedupe, group-not-city `everyStop`) and `anyHistorical`.
  `trip_detail_wear_section_test.dart` gains `_inSheet`/`_inPack` finders and
  a `_CityWeatherApiService` (keyed by city, so tests about what the sheet SAYS
  don't restate the visible-range derivation the revisited-city test pins),
  plus cases for the summary, collapsed-by-default, footnote-visible-while-
  collapsed, and the one-group inline rule.
