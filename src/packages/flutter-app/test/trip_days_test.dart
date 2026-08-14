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

  group('daysUntilTrip', () {
    final today = DateTime(2026, 8, 13, 22, 30); // time of day is ignored

    test('counts whole local days to the start date', () {
      expect(daysUntilTrip('2026-08-24', today), 11);
      expect(daysUntilTrip('2026-08-14', today), 1);
    });

    test('a trip starting today is 0, not null', () {
      expect(daysUntilTrip('2026-08-13', today), 0);
    });

    test('a started trip has no countdown', () {
      expect(daysUntilTrip('2026-08-12', today), isNull);
    });

    test('missing or garbage start dates yield null', () {
      expect(daysUntilTrip(null, today), isNull);
      expect(daysUntilTrip('not-a-date', today), isNull);
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

  group('tripHasStarted', () {
    final today = DateTime(2026, 8, 13, 22, 30); // time of day is ignored

    test('a trip starting today has started; tomorrow has not', () {
      expect(tripHasStarted('2026-08-13', '2026-08-20', today), isTrue);
      expect(tripHasStarted('2026-08-14', '2026-08-20', today), isFalse);
    });

    test('every past trip has started (the tripIsPast mirror)', () {
      expect(tripHasStarted('2026-07-01', '2026-07-05', today), isTrue);
      expect(tripIsPast('2026-07-01', '2026-07-05', today), isTrue);
    });

    test('an in-progress trip has started but is not past', () {
      expect(tripHasStarted('2026-08-10', '2026-08-20', today), isTrue);
      expect(tripIsPast('2026-08-10', '2026-08-20', today), isFalse);
    });

    test('falls back to the end date when there is no start', () {
      expect(tripHasStarted(null, '2026-07-05', today), isTrue);
      expect(tripHasStarted(null, '2026-09-05', today), isFalse);
    });

    test('undated and garbage trips have not started', () {
      expect(tripHasStarted(null, null, today), isFalse);
      expect(tripHasStarted('not-a-date', null, today), isFalse);
    });
  });

  group('traveledDayCount', () {
    final today = DateTime(2026, 8, 13, 22, 30); // time of day is ignored

    test('a finished trip counts in full, matching dayCount', () {
      expect(traveledDayCount('2026-06-10', '2026-06-14', today), 5);
      expect(dayCount('2026-06-10', '2026-06-14', const <int?>[]), 5);
    });

    test('an in-progress trip counts only the days lived through', () {
      // Day 1 was Aug 10; today is Aug 13 ⇒ 4 days behind us, 7 to go.
      expect(traveledDayCount('2026-08-10', '2026-08-20', today), 4);
    });

    test('a trip starting today counts its first day', () {
      expect(traveledDayCount('2026-08-13', '2026-08-20', today), 1);
    });

    test('a future trip counts nothing', () {
      expect(traveledDayCount('2026-08-14', '2026-08-20', today), 0);
      expect(traveledDayCount('2027-01-01', '2027-01-10', today), 0);
    });

    test('half-dated and undated trips count nothing (the dayCount rule)', () {
      expect(traveledDayCount('2026-06-10', null, today), 0);
      expect(traveledDayCount(null, '2026-06-14', today), 0);
      expect(traveledDayCount(null, null, today), 0);
      expect(traveledDayCount('junk', 'junk', today), 0);
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
