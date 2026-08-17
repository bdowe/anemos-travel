import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/utils/daily_spend.dart';

// daily_spend_test.dart — the one multiplication behind the daily food & drink
// suggestion. It has its own file because TWO surfaces read it (the total on
// the card and the planned_amount the button posts), and a card that shows one
// number while filing another is the drift docs/zen.md is about.

void main() {
  group('dailySpendTotal', () {
    test('is the per-person rate across the leg nights, for everyone', () {
      expect(
        dailySpendTotal(dailyAmount: 75, nights: 4, travelers: 2),
        600,
      );
    });

    test('one traveler is the rate times the nights', () {
      expect(dailySpendTotal(dailyAmount: 68, nights: 3, travelers: 1), 204);
    });

    // The multiplier is NIGHTS, and this is why: two legs share their
    // transition day, so per-city nights sum to the trip's own nights.
    // Counting days would bill each boundary twice and this would come to 654
    // over an 11-"day" trip that is really 9 nights long.
    test('per-city totals sum to a whole trip without double-counting', () {
      const rate = 50.0;
      final legs = [4, 3, 2]; // Sep 1-5, Sep 5-8, Sep 8-10 — 9 nights
      final total = legs.fold<double>(
          0,
          (sum, nights) =>
              sum + dailySpendTotal(dailyAmount: rate, nights: nights, travelers: 1));
      expect(legs.reduce((a, b) => a + b), 9);
      expect(total, 9 * rate);
    });

    test('a zero-night leg contributes nothing', () {
      expect(dailySpendTotal(dailyAmount: 90, nights: 0, travelers: 3), 0);
    });
  });

  group('clampTravelers', () {
    test('keeps the count inside the stepper range', () {
      expect(clampTravelers(0), kDailySpendMinTravelers);
      expect(clampTravelers(-4), kDailySpendMinTravelers);
      expect(clampTravelers(3), 3);
      expect(clampTravelers(99), kDailySpendMaxTravelers);
    });
  });

  test('a daily plan files under the canonical food category', () {
    // Never a localized label — the server bounds this exact string.
    expect(kDailySpendCategory, 'food');
  });
}
