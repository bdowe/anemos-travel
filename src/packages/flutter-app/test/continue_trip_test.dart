import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/recent_trip_provider.dart';
import 'package:travel_route_planner/utils/trip_format.dart';

/// The precedence ladder behind Home's "Continue where you left off" card.
///
/// The card used to read device storage directly, which meant a traveler with
/// saved trips saw nothing to continue on a new device, after clearing site
/// data, or after the anemos.travel cutover moved the origin out from under
/// localStorage. [continueTripOf] keeps the device's own memory as the
/// preferred answer and falls back to the trips list, which the server owns.
void main() {
  final today = DateTime(2026, 8, 14);

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

  const recorded = RecentTrip(
    tripId: 't1',
    title: 'Stale snapshot title',
    dateRange: 'Jan 1 – Jan 2',
  );

  group('rung 1 — the recorded trip, with live values', () {
    test('live title and dates beat the stored snapshot', () {
      final trips = [
        trip('t1',
            title: 'Renamed in the trip screen',
            start: '2026-09-01',
            end: '2026-09-08'),
      ];

      final result = continueTripOf(recorded, trips, null, today);

      expect(result?.tripId, 't1');
      expect(result?.title, 'Renamed in the trip screen');
      expect(result?.dateRange, tripDateRange('2026-09-01', '2026-09-08'));
    });
  });

  group('rung 2 — a recorded trip the owned list does not have', () {
    test('an unloaded list keeps the stored snapshot verbatim', () {
      final result = continueTripOf(recorded, const [], null, today);

      expect(result?.tripId, 't1');
      expect(result?.title, 'Stale snapshot title');
      expect(result?.dateRange, 'Jan 1 – Jan 2');
    });

    test('a shared trip is honored, not replaced by an owned one', () {
      // tripsProvider is the OWNED list — a trip shared with this traveler is
      // never in it, so absence must not be read as "deleted".
      final trips = [trip('owned', title: 'My own trip', start: '2026-09-01')];

      final result = continueTripOf(recorded, trips, null, today);

      expect(result?.tripId, 't1');
      expect(result?.title, 'Stale snapshot title');
    });
  });

  group('rung 3 — the fallback', () {
    test('takes the most recently updated trip', () {
      final trips = [
        trip('older', updatedAt: '2026-08-01T00:00:00Z'),
        trip('newest', updatedAt: '2026-08-13T00:00:00Z'),
        trip('middle', updatedAt: '2026-08-07T00:00:00Z'),
      ];

      expect(continueTripOf(null, trips, null, today)?.tripId, 'newest');
    });

    test('skips trips that have already happened', () {
      final trips = [
        trip('finished',
            start: '2026-07-01',
            end: '2026-07-10',
            updatedAt: '2026-08-13T00:00:00Z'),
        trip('ahead',
            start: '2026-09-01',
            end: '2026-09-08',
            updatedAt: '2026-08-02T00:00:00Z'),
      ];

      expect(continueTripOf(null, trips, null, today)?.tripId, 'ahead');
    });

    test('keeps an undated draft, which is not the same as past', () {
      final trips = [trip('draft')];

      expect(continueTripOf(null, trips, null, today)?.tripId, 'draft');
      expect(continueTripOf(null, trips, null, today)?.dateRange, isNull);
    });

    test('skips the live trip, which has its own card', () {
      final live = trip('live',
          start: '2026-08-13',
          end: '2026-08-16',
          updatedAt: '2026-08-14T00:00:00Z');
      final trips = [live, trip('other', updatedAt: '2026-08-02T00:00:00Z')];

      expect(continueTripOf(null, trips, live, today)?.tripId, 'other');
    });

    test('breaks an exact updatedAt tie on the newer createdAt', () {
      final trips = [
        trip('older-draft',
            updatedAt: '2026-08-10T00:00:00Z',
            createdAt: '2026-07-01T00:00:00Z'),
        trip('newer-draft',
            updatedAt: '2026-08-10T00:00:00Z',
            createdAt: '2026-07-20T00:00:00Z'),
      ];

      expect(continueTripOf(null, trips, null, today)?.tripId, 'newer-draft');
    });
  });

  group('rung 4 — nothing to continue', () {
    test('an account with no trips and no record yields null', () {
      expect(continueTripOf(null, const [], null, today), isNull);
    });

    test('an all-past account yields null rather than a finished trip', () {
      final trips = [
        trip('last-year', start: '2025-06-01', end: '2025-06-10'),
        trip('last-month', start: '2026-07-01', end: '2026-07-10'),
      ];

      expect(continueTripOf(null, trips, null, today), isNull);
    });

    test('the live trip alone yields null — it never stacks twice', () {
      final live = trip('live', start: '2026-08-13', end: '2026-08-16');

      expect(continueTripOf(null, [live], live, today), isNull);
    });

    test('a record pointing at the live trip falls through, not to itself',
        () {
      final live = trip('t1', start: '2026-08-13', end: '2026-08-16');

      expect(continueTripOf(recorded, [live], live, today), isNull);
    });
  });
}
