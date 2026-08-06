import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/utils/trip_days.dart';
import 'package:travel_route_planner/utils/trip_list_order.dart';

/// Trips-list display order (utils/trip_list_order.dart): upcoming soonest
/// first, undated drafts below dated plans, past trips grouped separately and
/// most recently finished first.

Trip _trip(
  String id, {
  String? start,
  String? end,
  String created = '2026-06-01T00:00:00Z',
}) =>
    Trip(
      id: id,
      title: id,
      status: 'draft',
      startDate: start,
      endDate: end,
      createdAt: created,
      updatedAt: created,
    );

// A fixed "today" keeps every case deterministic.
final _today = DateTime(2026, 8, 6);

void main() {
  group('tripIsPast', () {
    test('ended yesterday is past; ending today is not', () {
      expect(tripIsPast('2026-08-01', '2026-08-05', _today), isTrue);
      expect(tripIsPast('2026-08-01', '2026-08-06', _today), isFalse);
    });

    test('start-only trips fall back to the start date', () {
      expect(tripIsPast('2026-08-05', null, _today), isTrue);
      expect(tripIsPast('2026-08-06', null, _today), isFalse);
    });

    test('undated or unparseable trips are never past', () {
      expect(tripIsPast(null, null, _today), isFalse);
      expect(tripIsPast('not-a-date', 'also-no', _today), isFalse);
    });
  });

  group('partitionTripsForList', () {
    test('upcoming sorts soonest first regardless of server order', () {
      final r = partitionTripsForList(
        [
          _trip('far', start: '2026-12-01', end: '2026-12-10'),
          _trip('soon', start: '2026-08-24', end: '2026-09-27'),
          _trip('next', start: '2026-08-10', end: '2026-08-12'),
        ],
        _today,
      );
      expect(r.upcoming.map((t) => t.id), ['next', 'soon', 'far']);
      expect(r.past, isEmpty);
    });

    test('undated trips sit below dated ones, newest-created first', () {
      final r = partitionTripsForList(
        [
          _trip('draft-old', created: '2026-05-01T00:00:00Z'),
          _trip('dated', start: '2026-12-01', end: '2026-12-05'),
          _trip('draft-new', created: '2026-07-01T00:00:00Z'),
        ],
        _today,
      );
      expect(r.upcoming.map((t) => t.id), ['dated', 'draft-new', 'draft-old']);
    });

    test('past trips split off, most recently finished first', () {
      final r = partitionTripsForList(
        [
          _trip('long-ago', start: '2026-01-01', end: '2026-01-05'),
          _trip('upcoming', start: '2026-09-01', end: '2026-09-05'),
          _trip('just-ended', start: '2026-07-21', end: '2026-07-22'),
        ],
        _today,
      );
      expect(r.upcoming.map((t) => t.id), ['upcoming']);
      expect(r.past.map((t) => t.id), ['just-ended', 'long-ago']);
    });

    test('the live trip is exempt from the past group', () {
      // Started yesterday, no end date: tripIsPast files it under past, but
      // the Happening-Now spotlight considers it live — live wins.
      final r = partitionTripsForList(
        [_trip('live', start: '2026-08-05')],
        _today,
        liveTripId: 'live',
      );
      expect(r.upcoming.map((t) => t.id), ['live']);
      expect(r.past, isEmpty);
    });

    test('an end-only trip still sorts by date instead of joining drafts', () {
      final r = partitionTripsForList(
        [
          _trip('undated'),
          _trip('end-only', end: '2026-08-20'),
        ],
        _today,
      );
      expect(r.upcoming.map((t) => t.id), ['end-only', 'undated']);
    });

    test('equal dates tie-break newest-created first, deterministically', () {
      final r = partitionTripsForList(
        [
          _trip('older',
              start: '2026-09-01',
              end: '2026-09-05',
              created: '2026-05-01T00:00:00Z'),
          _trip('newer',
              start: '2026-09-01',
              end: '2026-09-05',
              created: '2026-07-01T00:00:00Z'),
        ],
        _today,
      );
      expect(r.upcoming.map((t) => t.id), ['newer', 'older']);
    });
  });
}
