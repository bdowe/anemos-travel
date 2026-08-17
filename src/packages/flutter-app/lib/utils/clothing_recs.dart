// What-to-wear derivation (specs/what-to-wear): deterministic clothing
// guidance from a leg's WeatherReport. Pure data — no widgets, no l10n;
// phrase text lives in the ARB and is mapped in the widget layer.
//
// This file is the client's ONE definition of weather thresholds: the
// trip-detail condition glyph consumes [rainLevel] and the recommendation
// bands live here, so the chip and the recs can never disagree. The wear
// rows' advisory suppression and same-guidance grouping live here too
// ([effectiveAdvisories]/[groupWearRegions]), so the fold compares exactly
// what the widget renders, and the sheet's trip-level packing summary
// ([packEssentials]) is derived from those same groups, so collapsing the
// per-city rows behind a disclosure loses nothing. The Go trip
// review keeps its own advisory constants (trip_review.go: rainProbPct,
// rainHistoricMM, hotThresholdC, coldThresholdC) for a different job —
// exception findings, not banded phrasing. They are deliberately NOT twinned,
// but [extremeHeatC]/[freezingNightC]/the rain-likely edges below equal them,
// so a Trip-health finding and a recommendation shown on the same screen
// always agree. Change an edge in one place → check the other.
//
// The report covers only days inside the leg's window (the server truncates
// to 14 days and starts mid-trip forecasts at today; historical reports carry
// last year's dates), and the derivation aggregates whatever days come back —
// no month-day matching, which is why the leap-day fallback in
// WeatherReport.dayFor is irrelevant here.

import '../models/weather.dart';
import 'leg_ranges.dart' show nightsBetween;

/// Rain banding shared by the day-chip glyph and the recommendations.
/// Forecast days key off the rain probability (%), historical days off
/// observed rainfall (mm).
enum RainLevel { none, some, likely }

const int rainLikelyPct = 60;
const int rainSomePct = 30;
const double rainLikelyMm = 5.0;
const double rainSomeMm = 1.0;

/// Chip-caption gate, not a band edge: the day chip prints "N% rain" from
/// this cutoff (below it the number is noise, not signal). Lives here so the
/// header's one-definition claim stays true.
const int rainChanceCaptionPct = 20;

/// Any-day condition edges. Kept equal to the Go review's advisory constants
/// (see header) so the two surfaces never contradict.
const double extremeHeatC = 34.0;
const double freezingNightC = 0.0;

/// Day–night spread that earns "bring layers".
const double bigSwingC = 12.0;

RainLevel rainLevel(WeatherDay day) {
  final pct = day.precipProbability;
  if (pct != null) {
    if (pct >= rainLikelyPct) return RainLevel.likely;
    if (pct >= rainSomePct) return RainLevel.some;
    return RainLevel.none;
  }
  if (day.precipMm >= rainLikelyMm) return RainLevel.likely;
  if (day.precipMm >= rainSomeMm) return RainLevel.some;
  return RainLevel.none;
}

/// Headline temperature band, from the MEDIAN of rounded daily highs so one
/// freak day can't flip the phrase (the envelope still exposes it in the
/// numbers). Edges in °C on the median daily high:
/// freezing ≤0 · cold 1–7 · cool 8–15 · mild 16–22 · warm 23–29 · hot ≥30.
enum TempBand { freezing, cold, cool, mild, warm, hot }

TempBand _bandOf(int medianHighC) {
  if (medianHighC <= 0) return TempBand.freezing;
  if (medianHighC <= 7) return TempBand.cold;
  if (medianHighC <= 15) return TempBand.cool;
  if (medianHighC <= 22) return TempBand.mild;
  if (medianHighC <= 29) return TempBand.warm;
  return TempBand.hot;
}

/// One leg's clothing guidance. Flags are any-day rules: packing is an
/// envelope decision — you carry the umbrella if any day needs it.
class ClothingRec {
  final TempBand band;

  /// Any day with [RainLevel.likely].
  final bool rainLikely;

  /// Any day whose high–low spread is ≥ [bigSwingC].
  final bool bigSwing;

  /// Any day at or above [extremeHeatC] / at or below [freezingNightC].
  final bool extremeHeat;
  final bool freezingNights;

  /// True for archive ("typical") reports beyond the forecast horizon.
  final bool historical;

  /// Temperature envelope over the leg: min of lows / max of highs, rounded.
  final int loC;
  final int hiC;

  const ClothingRec({
    required this.band,
    required this.rainLikely,
    required this.bigSwing,
    required this.extremeHeat,
    required this.freezingNights,
    required this.historical,
    required this.loC,
    required this.hiC,
  });
}

/// Derives the guidance for one leg's report; null when the report is empty
/// (loading, provider failure, undated leg — all render as "no recs").
ClothingRec? clothingRec(WeatherReport report) {
  final days = report.days;
  if (days.isEmpty) return null;

  final highs = days.map((d) => d.tempMaxC.round()).toList()..sort();
  // Even count takes the upper-middle element (pinned by test): for a packing
  // decision the warmer of the two middles is the safer headline.
  final medianHigh = highs[highs.length ~/ 2];

  var lo = days.first.tempMinC;
  var hi = days.first.tempMaxC;
  var rainy = false;
  var swing = false;
  var heat = false;
  var freeze = false;
  for (final d in days) {
    if (d.tempMinC < lo) lo = d.tempMinC;
    if (d.tempMaxC > hi) hi = d.tempMaxC;
    if (rainLevel(d) == RainLevel.likely) rainy = true;
    if (d.tempMaxC - d.tempMinC >= bigSwingC) swing = true;
    if (d.tempMaxC >= extremeHeatC) heat = true;
    if (d.tempMinC <= freezingNightC) freeze = true;
  }

  return ClothingRec(
    band: _bandOf(medianHigh),
    rainLikely: rainy,
    bigSwing: swing,
    extremeHeat: heat,
    freezingNights: freeze,
    historical: report.isHistorical,
    loC: lo.round(),
    hiC: hi.round(),
  );
}

/// Cross-region envelope for the sheet's header one-liner ("21°–31° · rain
/// likely"). Kind-neutral by design: the numbers make no forecast claim, so
/// the "typical" qualifier stays in the footnote.
({int loC, int hiC, bool rainLikely}) clothingSummary(List<ClothingRec> recs) {
  assert(recs.isNotEmpty, 'clothingSummary needs at least one rec');
  var lo = recs.first.loC;
  var hi = recs.first.hiC;
  var rainy = false;
  for (final r in recs) {
    if (r.loC < lo) lo = r.loC;
    if (r.hiC > hi) hi = r.hiC;
    if (r.rainLikely) rainy = true;
  }
  return (loC: lo, hiC: hi, rainLikely: rainy);
}

/// Advisory phrases that survive band suppression — the DISPLAYED set, in
/// render order (the widget iterates [WearAdvisory.values]). Flag phrases that
/// would restate the band's own advice are dropped: freezing/cold bands
/// already say coat (no "freezing nights"), cool and below already say layers
/// (no "big day–night range"), and the hot band already says sun protection
/// (no "very hot days"). Lives here rather than in the widget so the grouping
/// fold below compares exactly what gets rendered.
enum WearAdvisory { rainLikely, extremeHeat, freezingNights, bigSwing }

Set<WearAdvisory> effectiveAdvisories(ClothingRec rec) {
  final coldish = rec.band == TempBand.freezing || rec.band == TempBand.cold;
  return {
    if (rec.rainLikely) WearAdvisory.rainLikely,
    if (rec.extremeHeat && rec.band != TempBand.hot) WearAdvisory.extremeHeat,
    if (rec.freezingNights && !coldish) WearAdvisory.freezingNights,
    if (rec.bigSwing && !coldish && rec.band != TempBand.cool)
      WearAdvisory.bigSwing,
  };
}

/// One region's precomputed guidance: the leg label, its date window, and the
/// derived [ClothingRec]. The trip screen builds these from its own weather
/// watches (collapsed-row summaries must be fed by the parent), so the wear
/// widget stays display-only.
typedef WearRegionRec = ({
  String label,
  DateTime start,
  DateTime end,
  ClothingRec rec,
});

/// One DISPLAYED wear row: a run of date-adjacent regions whose displayed
/// guidance (band + effective advisories) is identical.
typedef WearGroup = ({
  List<String> labels,
  DateTime start,
  DateTime end,
  TempBand band,
  Set<WearAdvisory> advisories,
  bool historical,
  int loC,
  int hiC,
});

/// Days between one group's end and the next region's start that still count
/// as consecutive: adjacent legs share a boundary date under visible ranges
/// (distance 0), and a single skipped/undated day between two legs shouldn't
/// split otherwise-identical guidance. Gaps of two or more days (home between
/// legs) keep their own rows so a merged span never swallows a real gap.
const int wearMergeMaxGapDays = 1;

/// Folds per-leg regions into displayed rows: a region merges into the
/// previous group when the band and effective advisory set match AND the
/// dates are adjacent (see [wearMergeMaxGapDays]). Forecast-vs-historical
/// kind never blocks a merge — a group is historical if any member is, which
/// drives only the single footnote. The group envelope is min-of-los /
/// max-of-highs, so summing groups equals [clothingSummary] over the input
/// (the collapsed header and the expanded rows can't disagree). Display-layer
/// fold only: per-leg weather queries stay per-leg.
List<WearGroup> groupWearRegions(List<WearRegionRec> regions) {
  final groups = <WearGroup>[];
  for (final r in regions) {
    final adv = effectiveAdvisories(r.rec);
    if (groups.isNotEmpty) {
      final last = groups.last;
      final sameDisplay = last.band == r.rec.band &&
          last.advisories.length == adv.length &&
          last.advisories.containsAll(adv);
      if (sameDisplay &&
          nightsBetween(last.end, r.start) <= wearMergeMaxGapDays) {
        groups[groups.length - 1] = (
          // Dedupe revisits ("Paris, Paris") — labels repeat the locality.
          labels: [
            ...last.labels,
            if (!last.labels.contains(r.label)) r.label,
          ],
          start: last.start,
          end: r.end.isAfter(last.end) ? r.end : last.end,
          band: last.band,
          advisories: last.advisories,
          historical: last.historical || r.rec.historical,
          loC: r.rec.loC < last.loC ? r.rec.loC : last.loC,
          hiC: r.rec.hiC > last.hiC ? r.rec.hiC : last.hiC,
        );
        continue;
      }
    }
    groups.add((
      labels: [r.label],
      start: r.start,
      end: r.end,
      band: r.rec.band,
      advisories: adv,
      historical: r.rec.historical,
      loC: r.rec.loC,
      hiC: r.rec.hiC,
    ));
  }
  return groups;
}

/// Whether any displayed row is an archive ("typical") report — the gate for
/// the sheet's single historical footnote. Reads the regions rather than the
/// groups deliberately, and the two agree by construction: [groupWearRegions]
/// partitions the regions and ORs `historical` across each run, so
/// `groups.any((g) => g.historical)` and this are the same predicate. The
/// footnote qualifies the header envelope as well as the rows, so it renders
/// outside the collapsible city detail — hence a gate the sheet can call
/// without building groups.
bool anyHistorical(List<WearRegionRec> regions) =>
    regions.any((r) => r.rec.historical);

/// One thing to put in the bag. The sheet leads with these — the trip-level
/// answer — and the per-region rows sit behind a disclosure.
///
/// Values are in RENDER order (warmest clothing → lightest → weather gear).
/// [packEssentials] emits by iterating this list, so ordering is fixed at
/// declaration and nothing sorts: a comparator here would be both redundant
/// and, under Dart's insertion-sort fallback below 32 elements, untestable.
enum PackEssential {
  thermals,
  warmCoat,
  jacket,
  lightLayer,
  summerClothes,
  rainGear,
  sunProtection,
}

/// The objects a displayed row's phrasing asks for: the band phrase plus each
/// surviving advisory, re-expressed as things to pack. Every arm is non-empty
/// (pinned by test), so no rendered row can contribute nothing to the summary.
///
/// This is the ONE mapping — read it against the `wearBand*`/`wear*` ARB
/// strings the rows render (`WearRecsList._phrases`): the cold band says
/// "warm coat, hat, and gloves", so it yields [PackEssential.warmCoat]. Change
/// a phrase and change the arm with it, or the summary starts promising
/// something the detail below it never says.
Set<PackEssential> essentialsFor(
  TempBand band,
  Set<WearAdvisory> advisories,
) =>
    {
      ...switch (band) {
        TempBand.freezing => {PackEssential.thermals, PackEssential.warmCoat},
        TempBand.cold => {PackEssential.warmCoat},
        TempBand.cool => {PackEssential.jacket},
        TempBand.mild => {PackEssential.lightLayer},
        TempBand.warm => {
            PackEssential.summerClothes,
            PackEssential.lightLayer,
          },
        TempBand.hot => {
            PackEssential.summerClothes,
            PackEssential.sunProtection,
          },
      },
      for (final a in advisories)
        ...switch (a) {
          WearAdvisory.rainLikely => {PackEssential.rainGear},
          WearAdvisory.extremeHeat => {PackEssential.sunProtection},
          WearAdvisory.freezingNights => {PackEssential.jacket},
          WearAdvisory.bigSwing => {PackEssential.lightLayer},
        },
    };

/// One summary row: the thing to pack, the stops that ask for it, and whether
/// that is every stop on the trip (the labels then read as noise — "every
/// stop" says it shorter and stays true as the itinerary grows).
typedef PackItem = ({
  PackEssential essential,
  List<String> labels,
  bool everyStop,
});

/// The trip-level packing answer: the UNION of what the displayed rows already
/// say, grouped by object instead of by city.
///
/// Built by iterating [groupWearRegions] — the exact list `WearRecsList`
/// renders — so the summary and the city detail behind the disclosure cannot
/// disagree: every essential here is claimed by at least one visible row, and
/// every visible row contributes at least one essential (see [essentialsFor]).
/// That is what makes collapsing the rows lossless.
///
/// [PackItem.everyStop] counts contributing GROUPS, not labels: a merged run
/// is one stop's worth of guidance however many cities it names, so a
/// two-city group that folded because its guidance is identical must not read
/// as broader coverage than a single-city one.
List<PackItem> packEssentials(List<WearRegionRec> regions) {
  final groups = groupWearRegions(regions);
  final labelsBy = <PackEssential, List<String>>{};
  final groupsBy = <PackEssential, int>{};
  for (final g in groups) {
    for (final e in essentialsFor(g.band, g.advisories)) {
      final labels = labelsBy.putIfAbsent(e, () => <String>[]);
      for (final label in g.labels) {
        // Itinerary order, deduped — a revisited city must not read
        // "Paris, Paris" (the [groupWearRegions] label rule).
        if (!labels.contains(label)) labels.add(label);
      }
      groupsBy[e] = (groupsBy[e] ?? 0) + 1;
    }
  }
  return [
    for (final e in PackEssential.values)
      if (labelsBy[e] case final labels?)
        (
          essential: e,
          labels: labels,
          everyStop: groupsBy[e] == groups.length,
        ),
  ];
}
