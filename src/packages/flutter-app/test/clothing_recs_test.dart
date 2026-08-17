// Pins the what-to-wear derivation (specs/what-to-wear): band edges, the
// median-not-mean headline rule, any-day condition flags, the temperature
// envelope, and the rain thresholds the day-chip glyph shares via rainLevel.

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/weather.dart';
import 'package:travel_route_planner/utils/clothing_recs.dart';

WeatherDay day({
  double lo = 10,
  double hi = 20,
  double mm = 0,
  int? pct,
}) =>
    WeatherDay(
      date: '2026-09-15',
      tempMinC: lo,
      tempMaxC: hi,
      precipMm: mm,
      precipProbability: pct,
    );

WeatherReport forecast(List<WeatherDay> days) =>
    WeatherReport(location: 'Testville', kind: 'forecast', days: days);

WeatherReport historical(List<WeatherDay> days) =>
    WeatherReport(location: 'Testville', kind: 'historical', days: days);

void main() {
  group('rainLevel (shared with the day-chip glyph)', () {
    test('forecast bands on probability: 60 likely, 30 some, below none', () {
      expect(rainLevel(day(pct: 60)), RainLevel.likely);
      expect(rainLevel(day(pct: 59)), RainLevel.some);
      expect(rainLevel(day(pct: 30)), RainLevel.some);
      expect(rainLevel(day(pct: 29)), RainLevel.none);
      expect(rainLevel(day(pct: 0)), RainLevel.none);
    });

    test('historical bands on observed mm: 5 likely, 1 some, below none', () {
      expect(rainLevel(day(mm: 5.0)), RainLevel.likely);
      expect(rainLevel(day(mm: 4.9)), RainLevel.some);
      expect(rainLevel(day(mm: 1.0)), RainLevel.some);
      expect(rainLevel(day(mm: 0.9)), RainLevel.none);
    });

    test('probability wins over mm when both are present (forecast day)', () {
      expect(rainLevel(day(pct: 10, mm: 9.0)), RainLevel.none);
    });
  });

  group('temperature band from median daily high', () {
    TempBand bandFor(List<double> highs) =>
        clothingRec(forecast([for (final h in highs) day(hi: h, lo: h - 5)]))!
            .band;

    test('edges both sides', () {
      expect(bandFor([0]), TempBand.freezing);
      expect(bandFor([1]), TempBand.cold);
      expect(bandFor([7]), TempBand.cold);
      expect(bandFor([8]), TempBand.cool);
      expect(bandFor([15]), TempBand.cool);
      expect(bandFor([16]), TempBand.mild);
      expect(bandFor([22]), TempBand.mild);
      expect(bandFor([23]), TempBand.warm);
      expect(bandFor([29]), TempBand.warm);
      expect(bandFor([30]), TempBand.hot);
    });

    test('median, not mean: one freak hot day cannot flip a mild week', () {
      final rec = clothingRec(forecast([
        for (var i = 0; i < 6; i++) day(hi: 20, lo: 12),
        day(hi: 35, lo: 22),
      ]))!;
      expect(rec.band, TempBand.mild);
      // ...but the envelope and the any-day flag still expose it.
      expect(rec.hiC, 35);
      expect(rec.extremeHeat, isTrue);
    });

    test('even count takes the upper-middle element', () {
      // highs sorted [10, 20] -> index 1 -> 20 -> mild (not cool).
      final rec = clothingRec(forecast([day(hi: 10), day(hi: 20)]))!;
      expect(rec.band, TempBand.mild);
    });

    test('band uses rounded highs', () {
      expect(bandFor([29.4]), TempBand.warm);
      expect(bandFor([29.6]), TempBand.hot);
    });
  });

  group('any-day condition flags', () {
    test('one likely-rain day among dry days sets rainLikely', () {
      final rec = clothingRec(forecast([
        day(pct: 0),
        day(pct: 65),
        day(pct: 10),
      ]))!;
      expect(rec.rainLikely, isTrue);
    });

    test('some-level rain alone does not set rainLikely', () {
      final rec = clothingRec(forecast([day(pct: 45), day(pct: 30)]))!;
      expect(rec.rainLikely, isFalse);
    });

    test('bigSwing at spread 12, not 11', () {
      expect(clothingRec(forecast([day(hi: 21, lo: 10)]))!.bigSwing, isFalse);
      expect(clothingRec(forecast([day(hi: 22, lo: 10)]))!.bigSwing, isTrue);
    });

    test('extremeHeat at 34 / freezingNights at 0 (any day)', () {
      final rec = clothingRec(forecast([
        day(hi: 25, lo: 15),
        day(hi: 34, lo: 18),
      ]))!;
      expect(rec.extremeHeat, isTrue);
      expect(rec.freezingNights, isFalse);

      final cold = clothingRec(forecast([
        day(hi: 8, lo: 2),
        day(hi: 6, lo: 0),
      ]))!;
      expect(cold.extremeHeat, isFalse);
      expect(cold.freezingNights, isTrue);

      expect(clothingRec(forecast([day(hi: 33.9, lo: 0.1)]))!.extremeHeat,
          isFalse);
      expect(clothingRec(forecast([day(hi: 33.9, lo: 0.1)]))!.freezingNights,
          isFalse);
    });
  });

  group('envelope and report handling', () {
    test('loC/hiC are the rounded min-of-lows / max-of-highs', () {
      final rec = clothingRec(forecast([
        day(hi: 21.4, lo: 9.6),
        day(hi: 24.6, lo: 12.2),
      ]))!;
      expect(rec.loC, 10);
      expect(rec.hiC, 25);
    });

    test('empty report derives nothing', () {
      expect(clothingRec(const WeatherReport()), isNull);
      expect(clothingRec(forecast(const [])), isNull);
    });

    test('historical passthrough', () {
      expect(clothingRec(historical([day()]))!.historical, isTrue);
      expect(clothingRec(forecast([day()]))!.historical, isFalse);
    });
  });

  group('clothingSummary', () {
    test('merges the cross-region envelope and any-region rain', () {
      final lisbon = clothingRec(forecast([day(hi: 28, lo: 17)]))!;
      final porto = clothingRec(forecast([day(hi: 21, lo: 12, pct: 70)]))!;
      final s = clothingSummary([lisbon, porto]);
      expect(s.loC, 12);
      expect(s.hiC, 28);
      expect(s.rainLikely, isTrue);
    });

    test('no rain anywhere stays dry', () {
      final s = clothingSummary([clothingRec(forecast([day()]))!]);
      expect(s.rainLikely, isFalse);
    });
  });

  group('effectiveAdvisories (the displayed set after band suppression)', () {
    test('rain always survives, any band', () {
      expect(effectiveAdvisories(rec(band: TempBand.hot, rainLikely: true)),
          contains(WearAdvisory.rainLikely));
      expect(effectiveAdvisories(rec(band: TempBand.freezing, rainLikely: true)),
          contains(WearAdvisory.rainLikely));
    });

    test('extremeHeat suppressed only when the band already says hot', () {
      expect(effectiveAdvisories(rec(band: TempBand.hot, extremeHeat: true)),
          isNot(contains(WearAdvisory.extremeHeat)));
      expect(effectiveAdvisories(rec(band: TempBand.warm, extremeHeat: true)),
          contains(WearAdvisory.extremeHeat));
    });

    test('freezingNights suppressed for freezing/cold, kept for cool', () {
      expect(
          effectiveAdvisories(rec(band: TempBand.cold, freezingNights: true)),
          isNot(contains(WearAdvisory.freezingNights)));
      expect(
          effectiveAdvisories(
              rec(band: TempBand.freezing, freezingNights: true)),
          isNot(contains(WearAdvisory.freezingNights)));
      expect(
          effectiveAdvisories(rec(band: TempBand.cool, freezingNights: true)),
          contains(WearAdvisory.freezingNights));
    });

    test('bigSwing suppressed for cool and below, kept for mild', () {
      expect(effectiveAdvisories(rec(band: TempBand.cool, bigSwing: true)),
          isNot(contains(WearAdvisory.bigSwing)));
      expect(effectiveAdvisories(rec(band: TempBand.cold, bigSwing: true)),
          isNot(contains(WearAdvisory.bigSwing)));
      expect(effectiveAdvisories(rec(band: TempBand.mild, bigSwing: true)),
          contains(WearAdvisory.bigSwing));
    });

    test('no flags means no advisories', () {
      expect(effectiveAdvisories(rec()), isEmpty);
    });
  });

  group('groupWearRegions', () {
    test('consecutive same-guidance legs fold into one row', () {
      final groups = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27', rec(lo: 15, hi: 26)),
        region('Kraków', '2026-08-27', '2026-09-01', rec(lo: 16, hi: 27)),
        region('Berlin', '2026-09-01', '2026-09-04', rec(lo: 17, hi: 25)),
      ]);
      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.labels, ['Prague', 'Kraków', 'Berlin']);
      expect(g.start, DateTime.parse('2026-08-24'));
      expect(g.end, DateTime.parse('2026-09-04'));
      expect(g.band, TempBand.warm);
      expect(g.loC, 15);
      expect(g.hiC, 27);
    });

    test('a different band splits', () {
      final groups = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27', rec(band: TempBand.warm)),
        region('Gothenburg', '2026-08-27', '2026-08-29',
            rec(band: TempBand.mild, lo: 14, hi: 18)),
      ]);
      expect(groups, hasLength(2));
    });

    test('same band but rain-vs-dry splits (advisory set is the key)', () {
      final groups = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27', rec(rainLikely: true)),
        region('Kraków', '2026-08-27', '2026-09-01', rec()),
      ]);
      expect(groups, hasLength(2));
    });

    test('a suppressed-flag mismatch still merges (displayed content rule)', () {
      // Both display just "Hot — …": extremeHeat is suppressed for the hot
      // band, so the raw-flag difference must not block the merge.
      final groups = groupWearRegions([
        region('Athens', '2026-08-24', '2026-08-27',
            rec(band: TempBand.hot, extremeHeat: true, lo: 25, hi: 36)),
        region('Santorini', '2026-08-27', '2026-08-30',
            rec(band: TempBand.hot, lo: 24, hi: 31)),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.advisories, isEmpty);
      expect(groups.single.loC, 24);
      expect(groups.single.hiC, 36);
    });

    test('gap rule: one day apart merges, two days apart splits', () {
      final oneDay = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27', rec()),
        region('Kraków', '2026-08-28', '2026-08-31', rec()),
      ]);
      expect(oneDay, hasLength(1));

      final twoDays = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27', rec()),
        region('Kraków', '2026-08-29', '2026-09-01', rec()),
      ]);
      expect(twoDays, hasLength(2));
    });

    test('forecast-vs-historical kind never blocks; group ORs historical', () {
      final groups = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27', rec()),
        region('Kraków', '2026-08-27', '2026-09-01', rec(historical: true)),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.historical, isTrue);
    });

    test('an adjacent revisit dedupes the label', () {
      final groups = groupWearRegions([
        region('Paris', '2026-09-15', '2026-09-16', rec()),
        region('Paris', '2026-09-17', '2026-09-18', rec()),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.labels, ['Paris']);
    });

    test('group envelope agrees with clothingSummary over the input', () {
      final recs = [
        rec(lo: 15, hi: 26, rainLikely: true),
        rec(band: TempBand.mild, lo: 10, hi: 18),
        rec(lo: 12, hi: 30),
      ];
      final groups = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27', recs[0]),
        region('Gothenburg', '2026-08-27', '2026-08-30', recs[1]),
        region('Lisbon', '2026-08-30', '2026-09-02', recs[2]),
      ]);
      var lo = groups.first.loC;
      var hi = groups.first.hiC;
      var rainy = false;
      for (final g in groups) {
        if (g.loC < lo) lo = g.loC;
        if (g.hiC > hi) hi = g.hiC;
        if (g.advisories.contains(WearAdvisory.rainLikely)) rainy = true;
      }
      final s = clothingSummary(recs);
      expect(lo, s.loC);
      expect(hi, s.hiC);
      expect(rainy, s.rainLikely);
    });

    test('empty in, empty out; a single region passes through', () {
      expect(groupWearRegions([]), isEmpty);
      final groups = groupWearRegions([
        region('Prague', '2026-08-24', '2026-08-27',
            rec(rainLikely: true, historical: true)),
      ]);
      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.labels, ['Prague']);
      expect(g.advisories, {WearAdvisory.rainLikely});
      expect(g.historical, isTrue);
      expect((g.loC, g.hiC), (15, 26));
    });
  });

  group('essentialsFor', () {
    test('every band asks for something', () {
      for (final band in TempBand.values) {
        expect(essentialsFor(band, const {}), isNotEmpty,
            reason: '$band contributes nothing to the summary');
      }
    });

    test('the band table matches the phrases the rows render', () {
      expect(essentialsFor(TempBand.freezing, const {}),
          {PackEssential.thermals, PackEssential.warmCoat});
      expect(essentialsFor(TempBand.cold, const {}), {PackEssential.warmCoat});
      expect(essentialsFor(TempBand.cool, const {}), {PackEssential.jacket});
      expect(essentialsFor(TempBand.mild, const {}), {PackEssential.lightLayer});
      expect(essentialsFor(TempBand.warm, const {}),
          {PackEssential.summerClothes, PackEssential.lightLayer});
      expect(essentialsFor(TempBand.hot, const {}),
          {PackEssential.summerClothes, PackEssential.sunProtection});
    });

    test('every advisory contributes its object', () {
      // Paired with a band that does NOT already imply it, so each row proves
      // the advisory arm rather than the band's.
      const table = {
        WearAdvisory.rainLikely: (TempBand.mild, PackEssential.rainGear),
        WearAdvisory.extremeHeat: (TempBand.mild, PackEssential.sunProtection),
        WearAdvisory.freezingNights: (TempBand.mild, PackEssential.jacket),
        WearAdvisory.bigSwing: (TempBand.hot, PackEssential.lightLayer),
      };
      expect(table.keys, WearAdvisory.values.toSet(),
          reason: 'a new advisory needs a row here');
      table.forEach((advisory, expected) {
        final (band, essential) = expected;
        final bare = essentialsFor(band, const {});
        expect(bare, isNot(contains(essential)),
            reason: 'pick a band that does not already imply $essential');
        expect(essentialsFor(band, {advisory}), containsAll([...bare, essential]));
      });
    });

    test('an advisory restating the band is idempotent, not a second row', () {
      // "big day–night range, bring layers" on a mild leg asks for the same
      // light layer "Mild — light layers" already does. One object, one row —
      // the union is what the summary shows.
      expect(essentialsFor(TempBand.mild, {WearAdvisory.bigSwing}),
          essentialsFor(TempBand.mild, const {}));
    });
  });

  group('packEssentials', () {
    // The screenshot trip that prompted the summary: eight distinct stories,
    // none of which fold.
    List<WearRegionRec> europeTrip() => [
          region('Amsterdam', '2026-08-24', '2026-08-26',
              rec(band: TempBand.mild, lo: 13, hi: 22)),
          region('Prague', '2026-08-26', '2026-08-29', rec(lo: 17, hi: 27)),
          region('Kraków', '2026-08-29', '2026-09-04',
              rec(lo: 15, hi: 32, rainLikely: true, bigSwing: true)),
          region('Copenhagen', '2026-09-04', '2026-09-07',
              rec(band: TempBand.mild, lo: 13, hi: 23, rainLikely: true)),
          region('Berlin', '2026-09-07', '2026-09-10',
              rec(band: TempBand.mild, lo: 12, hi: 24)),
          region('Gothenburg', '2026-09-10', '2026-09-13',
              rec(band: TempBand.mild, lo: 11, hi: 22, rainLikely: true)),
          region('Sorrento', '2026-09-13', '2026-09-18', rec(lo: 18, hi: 28)),
          region('Rome', '2026-09-18', '2026-09-22',
              rec(band: TempBand.hot, lo: 19, hi: 32, bigSwing: true)),
        ];

    test('is exactly the union of what the displayed rows say', () {
      final regions = europeTrip();
      final groups = groupWearRegions(regions);
      expect(groups, hasLength(8), reason: 'fixture must not fold');

      final fromRows = <PackEssential>{
        for (final g in groups) ...essentialsFor(g.band, g.advisories),
      };
      final summary =
          packEssentials(regions).map((i) => i.essential).toSet();
      expect(summary, fromRows);
    });

    test('renders in PackEssential order, whatever the itinerary order', () {
      final forward = packEssentials(europeTrip()).map((i) => i.essential);
      expect(forward, [
        PackEssential.lightLayer,
        PackEssential.summerClothes,
        PackEssential.rainGear,
        PackEssential.sunProtection,
      ]);
      // Reversing the trip reverses the labels, never the row order.
      final reversed =
          packEssentials(europeTrip().reversed.toList()).map((i) => i.essential);
      expect(reversed, forward);
    });

    test('attributes each object to its stops, in itinerary order', () {
      final items = {
        for (final i in packEssentials(europeTrip())) i.essential: i,
      };
      expect(items[PackEssential.summerClothes]!.labels,
          ['Prague', 'Kraków', 'Sorrento', 'Rome']);
      expect(items[PackEssential.rainGear]!.labels,
          ['Kraków', 'Copenhagen', 'Gothenburg']);
      expect(items[PackEssential.sunProtection]!.labels, ['Rome']);
    });

    test('everyStop only when every displayed group asks for it', () {
      final items = {
        for (final i in packEssentials(europeTrip())) i.essential: i,
      };
      // Every band on this trip wants a light layer; nothing else does.
      expect(items[PackEssential.lightLayer]!.everyStop, isTrue);
      expect(items[PackEssential.summerClothes]!.everyStop, isFalse);
      expect(items[PackEssential.rainGear]!.everyStop, isFalse);
    });

    test('everyStop counts GROUPS, not cities — a merged run is one', () {
      // Two mild+rain legs fold into one group; the lone hot leg is the other.
      // Rain covers 2 of 3 cities but only 1 of 2 displayed rows.
      final regions = [
        region('Bergen', '2026-09-01', '2026-09-04',
            rec(band: TempBand.mild, rainLikely: true)),
        region('Ålesund', '2026-09-04', '2026-09-07',
            rec(band: TempBand.mild, rainLikely: true)),
        region('Seville', '2026-09-09', '2026-09-13', rec(band: TempBand.hot)),
      ];
      expect(groupWearRegions(regions), hasLength(2));
      final items = {
        for (final i in packEssentials(regions)) i.essential: i,
      };
      expect(items[PackEssential.rainGear]!.everyStop, isFalse);
      expect(items[PackEssential.rainGear]!.labels, ['Bergen', 'Ålesund']);
      expect(items[PackEssential.summerClothes]!.labels, ['Seville']);
    });

    test('a revisited city is named once', () {
      final items = packEssentials([
        region('Paris', '2026-09-15', '2026-09-17', rec(rainLikely: true)),
        region('Nice', '2026-09-17', '2026-09-20', rec(band: TempBand.hot)),
        region('Paris', '2026-09-20', '2026-09-22', rec(rainLikely: true)),
      ]);
      final rain =
          items.firstWhere((i) => i.essential == PackEssential.rainGear);
      expect(rain.labels, ['Paris']);
    });

    test('a cold trip asks for the cold things', () {
      final items = packEssentials([
        region('Tromsø', '2026-01-05', '2026-01-09',
            rec(band: TempBand.freezing, lo: -12, hi: -3, freezingNights: true)),
      ]).map((i) => i.essential);
      // freezingNights is suppressed on a freezing band, so no jacket row —
      // the coat already said it.
      expect(items, [PackEssential.thermals, PackEssential.warmCoat]);
    });

    test('empty in, empty out', () {
      expect(packEssentials([]), isEmpty);
    });
  });

  group('anyHistorical', () {
    test('agrees with the grouped rows it gates the footnote for', () {
      for (final regions in [
        <WearRegionRec>[],
        [region('Prague', '2026-08-24', '2026-08-27', rec())],
        [
          region('Prague', '2026-08-24', '2026-08-27', rec()),
          region('Lisbon', '2026-09-10', '2026-09-14', rec(historical: true)),
        ],
        [region('Lisbon', '2026-09-10', '2026-09-14', rec(historical: true))],
      ]) {
        expect(
          anyHistorical(regions),
          groupWearRegions(regions).any((g) => g.historical),
        );
      }
    });
  });
}

/// Direct [ClothingRec] builder for grouping tests — grouping consumes the
/// derived rec, so these bypass the day-level derivation pinned above.
ClothingRec rec({
  TempBand band = TempBand.warm,
  bool rainLikely = false,
  bool bigSwing = false,
  bool extremeHeat = false,
  bool freezingNights = false,
  bool historical = false,
  int lo = 15,
  int hi = 26,
}) =>
    ClothingRec(
      band: band,
      rainLikely: rainLikely,
      bigSwing: bigSwing,
      extremeHeat: extremeHeat,
      freezingNights: freezingNights,
      historical: historical,
      loC: lo,
      hiC: hi,
    );

WearRegionRec region(String label, String start, String end, ClothingRec r) => (
      label: label,
      start: DateTime.parse(start),
      end: DateTime.parse(end),
      rec: r,
    );
