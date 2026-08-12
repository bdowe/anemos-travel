import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/utils/trip_days.dart';

void main() {
  group('tripDayOn', () {
    const start = '2026-06-10';
    const end = '2026-06-14'; // 5-day trip

    test('a date inside the range maps to its 1-based day', () {
      expect(tripDayOn(start, end, DateTime(2026, 6, 12)), 3);
    });

    test('day-1 boundary: the start date itself is day 1', () {
      expect(tripDayOn(start, end, DateTime(2026, 6, 10)), 1);
    });

    test('last-day boundary: the end date is the final day', () {
      expect(tripDayOn(start, end, DateTime(2026, 6, 14)), 5);
    });

    test('before the range is null', () {
      expect(tripDayOn(start, end, DateTime(2026, 6, 9)), isNull);
    });

    test('after the range is null', () {
      expect(tripDayOn(start, end, DateTime(2026, 6, 15)), isNull);
    });

    test('time of day is ignored (truncated to the local date)', () {
      expect(tripDayOn(start, end, DateTime(2026, 6, 12, 23, 59)), 3);
      expect(tripDayOn(start, end, DateTime(2026, 6, 14, 18, 30)), 5);
    });

    test('missing or garbage start date is null', () {
      expect(tripDayOn(null, end, DateTime(2026, 6, 12)), isNull);
      expect(tripDayOn('', end, DateTime(2026, 6, 12)), isNull);
      expect(tripDayOn('not-a-date', end, DateTime(2026, 6, 12)), isNull);
    });

    test('missing end date leaves the trip open-ended past day 1', () {
      // Mirrors the add-to-trip sheet's original behavior: only the lower
      // bound applies when the end does not parse.
      expect(tripDayOn(start, null, DateTime(2026, 7, 1)), 22);
      expect(tripDayOn(start, 'garbage', DateTime(2026, 6, 9)), isNull);
    });
  });

  group('dayCount', () {
    test('date span wins when items are untagged', () {
      expect(dayCount('2026-06-10', '2026-06-14', [null, null]), 5);
    });

    test('a tagged day beyond the span wins', () {
      expect(dayCount('2026-06-10', '2026-06-14', [2, 9, null]), 9);
    });

    test('tagged days alone work without trip dates', () {
      expect(dayCount(null, null, [1, 3]), 3);
    });

    test('no dates and no tags is 0', () {
      expect(dayCount(null, null, const <int?>[]), 0);
      expect(dayCount('junk', 'junk', [null]), 0);
    });
  });

  group('stayCoversDate', () {
    const checkIn = '2026-06-10';
    const checkOut = '2026-06-13';

    test('the check-in date is covered', () {
      expect(stayCoversDate(checkIn, checkOut, DateTime(2026, 6, 10)), isTrue);
    });

    test('nights in between are covered', () {
      expect(stayCoversDate(checkIn, checkOut, DateTime(2026, 6, 12)), isTrue);
    });

    test('the check-out date is NOT covered (checkout-exclusive)', () {
      expect(stayCoversDate(checkIn, checkOut, DateTime(2026, 6, 13)), isFalse);
    });

    test('dates outside the stay are not covered', () {
      expect(stayCoversDate(checkIn, checkOut, DateTime(2026, 6, 9)), isFalse);
      expect(stayCoversDate(checkIn, checkOut, DateTime(2026, 6, 14)), isFalse);
    });

    test('missing or garbage dates are never covered', () {
      expect(stayCoversDate(null, checkOut, DateTime(2026, 6, 11)), isFalse);
      expect(stayCoversDate(checkIn, null, DateTime(2026, 6, 11)), isFalse);
      expect(stayCoversDate('junk', checkOut, DateTime(2026, 6, 11)), isFalse);
    });

    test("the queried date's time of day is ignored", () {
      expect(
        stayCoversDate(checkIn, checkOut, DateTime(2026, 6, 12, 23, 59)),
        isTrue,
      );
    });
  });

  group('stayCoversAnyNight (specs/map-city-focus)', () {
    const checkIn = '2026-06-10';
    const checkOut = '2026-06-12'; // nights of Jun 10 + Jun 11

    test('overlapping ranges match', () {
      expect(
        stayCoversAnyNight(
            checkIn, checkOut, DateTime(2026, 6, 11), DateTime(2026, 6, 14)),
        isTrue,
      );
    });

    test('checkout-exclusive on BOTH sides', () {
      // The range's end night is exclusive: [Jun 8, Jun 10) holds nights
      // Jun 8-9, none covered by a Jun 10 check-in…
      expect(
        stayCoversAnyNight(
            checkIn, checkOut, DateTime(2026, 6, 8), DateTime(2026, 6, 10)),
        isFalse,
      );
      // …and the stay's checkout night never counts either.
      expect(
        stayCoversAnyNight(
            checkIn, checkOut, DateTime(2026, 6, 12), DateTime(2026, 6, 14)),
        isFalse,
      );
    });

    test('a zero-night range matches nothing', () {
      expect(
        stayCoversAnyNight(
            checkIn, checkOut, DateTime(2026, 6, 10), DateTime(2026, 6, 10)),
        isFalse,
      );
    });

    test('missing or garbage stay dates never match', () {
      expect(
        stayCoversAnyNight(
            null, checkOut, DateTime(2026, 6, 10), DateTime(2026, 6, 12)),
        isFalse,
      );
      expect(
        stayCoversAnyNight(
            'junk', checkOut, DateTime(2026, 6, 10), DateTime(2026, 6, 12)),
        isFalse,
      );
    });
  });
}
