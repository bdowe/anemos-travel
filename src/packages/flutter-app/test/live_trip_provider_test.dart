import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';

/// Pure tests for liveTripOf (specs/happening-now): liveness is
/// tripDayOn != null (device-local, end-day inclusive); among several live
/// trips the latest start date wins, ties broken by list order.
Trip _trip(String id, {String? start, String? end}) => Trip(
      id: id,
      title: 'Trip $id',
      startDate: start,
      endDate: end,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  final now = DateTime(2026, 7, 16, 14, 30);
  String rel(int days) => _iso(now.add(Duration(days: days)));

  test('no live trip returns null', () {
    final trips = [
      _trip('past', start: rel(-10), end: rel(-3)),
      _trip('future', start: rel(3), end: rel(10)),
    ];
    expect(liveTripOf(trips, now), isNull);
    expect(liveTripOf(const [], now), isNull);
  });

  test('a single live trip is picked', () {
    final trips = [
      _trip('past', start: rel(-10), end: rel(-3)),
      _trip('live', start: rel(-1), end: rel(1)),
      _trip('future', start: rel(3), end: rel(10)),
    ];
    expect(liveTripOf(trips, now)?.id, 'live');
  });

  test('two live trips: the latest start date wins regardless of order', () {
    final older = _trip('older', start: rel(-5), end: rel(2));
    final newer = _trip('newer', start: rel(-1), end: rel(4));
    expect(liveTripOf([older, newer], now)?.id, 'newer');
    expect(liveTripOf([newer, older], now)?.id, 'newer');
  });

  test('same start date ties break by list order', () {
    final a = _trip('a', start: rel(-1), end: rel(2));
    final b = _trip('b', start: rel(-1), end: rel(3));
    expect(liveTripOf([a, b], now)?.id, 'a');
    expect(liveTripOf([b, a], now)?.id, 'b');
  });

  test('undated trips are skipped', () {
    final trips = [
      _trip('undated'),
      _trip('endless', start: rel(-2)),
    ];
    // The undated trip is never live; the open-ended dated one is.
    expect(liveTripOf(trips, now)?.id, 'endless');
    expect(liveTripOf([_trip('undated')], now), isNull);
  });

  test('a trip ending today is still live (end-day inclusive)', () {
    final trips = [_trip('lastday', start: rel(-4), end: rel(0))];
    expect(liveTripOf(trips, now)?.id, 'lastday');
  });

  test('ended yesterday or starting tomorrow is not live', () {
    expect(
        liveTripOf([_trip('done', start: rel(-4), end: rel(-1))], now), isNull);
    expect(
        liveTripOf([_trip('soon', start: rel(1), end: rel(4))], now), isNull);
  });
}
