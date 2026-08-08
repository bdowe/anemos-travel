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
}
