import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/departing_trip_provider.dart';

/// Which trip Home's "Before you go" section is about.
///
/// It used to be whichever trip [continueTripOf] returned — the last one this
/// device VIEWED, falling back to the most recently UPDATED. Neither key is
/// departure, so an account with two trips could get readiness for the wrong
/// one, under a header that named no trip at all. [departingTripOf] orders on
/// the only thing "before you go" can mean: how soon you leave.
void main() {
  final today = DateTime(2026, 8, 22);

  Trip trip(
    String id, {
    String title = 'A trip',
    String? start,
    String? end,
    String updatedAt = '2026-08-01T00:00:00Z',
    String createdAt = '2026-07-01T00:00:00Z',
  }) =>
      Trip(
        id: id,
        title: title,
        startDate: start,
        endDate: end,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  group('picks the trip departing soonest', () {
    test('the nearest departure wins, not the most recently touched', () {
      // The regression, exactly: the October trip is the one just edited, so
      // continueTripOf would name it — while Friday's trip goes unmentioned.
      final trips = [
        trip('october',
            title: 'Kyoto in October',
            start: '2026-10-12',
            updatedAt: '2026-08-22T09:00:00Z'),
        trip('friday',
            title: 'Northern Europe',
            start: '2026-08-28',
            updatedAt: '2026-07-02T00:00:00Z'),
      ];

      final result = departingTripOf(trips, null, today);

      expect(result?.tripId, 'friday');
      expect(result?.title, 'Northern Europe');
      expect(result?.daysUntil, 6);
    });

    test('list order does not decide it', () {
      final trips = [
        trip('later', start: '2026-09-02'),
        trip('sooner', start: '2026-08-25'),
        trip('latest', start: '2026-09-04'),
      ];

      expect(departingTripOf(trips, null, today)?.tripId, 'sooner');
    });

    test('same departure date breaks to the more recently touched trip', () {
      final trips = [
        trip('stale', start: '2026-08-25', updatedAt: '2026-08-01T00:00:00Z'),
        trip('fresh', start: '2026-08-25', updatedAt: '2026-08-20T00:00:00Z'),
      ];

      expect(departingTripOf(trips, null, today)?.tripId, 'fresh');
    });
  });

  group('the window', () {
    test('a trip on the last day of the window still qualifies', () {
      final trips = [trip('t', start: '2026-09-05')]; // exactly 14 days out

      expect(departingTripOf(trips, null, today)?.daysUntil,
          kBeforeYouGoWindowDays);
    });

    test('a trip one day past the window does not', () {
      final trips = [trip('t', start: '2026-09-06')]; // 15 days out

      expect(departingTripOf(trips, null, today), isNull);
    });

    test('a nearer trip outside nothing — an empty list — is null', () {
      expect(departingTripOf([], null, today), isNull);
    });

    test('a far trip does not suppress a near one', () {
      final trips = [
        trip('far', start: '2027-01-01'),
        trip('near', start: '2026-08-24'),
      ];

      expect(departingTripOf(trips, null, today)?.tripId, 'near');
    });
  });

  group('what never qualifies', () {
    test('an undated trip', () {
      expect(departingTripOf([trip('t')], null, today), isNull);
    });

    test('a trip whose start has already gone by', () {
      final trips = [trip('t', start: '2026-08-10', end: '2026-08-12')];

      expect(departingTripOf(trips, null, today), isNull);
    });

    test('the live trip — it has its own card, and it has begun', () {
      final live = trip('live', start: '2026-08-20', end: '2026-08-30');

      expect(departingTripOf([live], live, today), isNull);
    });

    test(
        'the live trip is skipped even when it starts TODAY, where daysUntil '
        'is 0 rather than null', () {
      final live = trip('live', start: '2026-08-22', end: '2026-08-30');
      final next = trip('next', title: 'The one after', start: '2026-09-01');

      final result = departingTripOf([live, next], live, today);

      expect(result?.tripId, 'next');
    });
  });

  test('a trip departing today qualifies when it is not the live one', () {
    // No end date and not claimed by liveTripOf: departure is today, which is
    // when readiness matters most.
    final trips = [trip('t', title: 'Wheels up', start: '2026-08-22')];

    final result = departingTripOf(trips, null, today);

    expect(result?.tripId, 't');
    expect(result?.daysUntil, 0);
  });

  test('carries the values the card prints', () {
    final trips = [trip('t', title: 'Northern Europe', start: '2026-08-28')];

    final result = departingTripOf(trips, null, today);

    expect(result?.title, 'Northern Europe');
    expect(result?.startDate, '2026-08-28');
    expect(result?.daysUntil, 6);
  });
}
