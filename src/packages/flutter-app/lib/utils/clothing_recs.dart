// What-to-wear derivation (specs/what-to-wear): deterministic clothing
// guidance from a leg's WeatherReport. Pure data — no widgets, no l10n;
// phrase text lives in the ARB and is mapped in the widget layer.
//
// This file is the client's ONE definition of weather thresholds: the
// trip-detail condition glyph consumes [rainLevel] and the recommendation
// bands live here, so the chip and the recs can never disagree. The wear
// rows' advisory suppression and same-guidance grouping live here too
// ([effectiveAdvisories]/[groupWearRegions]), so the fold compares exactly
// what the widget renders. The Go trip
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

/// Cross-region envelope for the collapsed one-liner ("21°–31° · rain
/// likely"). Kind-neutral by design: the numbers make no forecast claim, so
/// the "typical" qualifier stays on the expanded per-leg rows.
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
