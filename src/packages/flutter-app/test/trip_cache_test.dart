import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/services/trip_cache.dart';

Trip _trip(String id, {String title = 'Trip'}) => Trip(
      id: id,
      title: title,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('isNetworkError', () {
    test('classifies connection-level failures as network errors', () {
      expect(TripCache.isNetworkError(http.ClientException('refused')), isTrue);
      expect(TripCache.isNetworkError(TimeoutException('slow')), isTrue);
      expect(
          TripCache.isNetworkError(
              Exception('SocketException: Failed host lookup')),
          isTrue);
    });

    test('HTTP status errors are NOT network errors (no cache fallback)', () {
      // TripsApiService throws these for non-200 responses; a 403/404 must
      // never resurrect a trip from cache.
      expect(TripCache.isNetworkError(Exception('Failed to load trip (403)')),
          isFalse);
      expect(TripCache.isNetworkError(Exception('Failed to load trips (404)')),
          isFalse);
      expect(TripCache.isNetworkError(Exception('Failed to load trips (500)')),
          isFalse);
      expect(TripCache.isNetworkError(StateError('bug')), isFalse);
    });
  });

  group('trip list cache', () {
    test('round-trips the list with a saved-at timestamp', () async {
      final cache = TripCache('u1');
      final before = DateTime.now();
      await cache.writeList([_trip('a', title: 'Athens'), _trip('b')]);
      final cached = await cache.readList();
      expect(cached, isNotNull);
      expect(cached!.trips.map((t) => t.id), ['a', 'b']);
      expect(cached.trips.first.title, 'Athens');
      expect(cached.savedAt.isBefore(before), isFalse);
      expect(cached.savedAt.isAfter(DateTime.now()), isFalse);
    });

    test('users are isolated and anonymous sessions no-op', () async {
      await TripCache('u1').writeList([_trip('a')]);
      expect(await TripCache('u2').readList(), isNull);
      final anon = TripCache(null);
      await anon.writeList([_trip('x')]); // no-op, no throw
      expect(await anon.readList(), isNull);
    });

    test('corrupt entry reads as a miss', () async {
      SharedPreferences.setMockInitialValues(
          {'trip_cache.u1.list': 'not json'});
      expect(await TripCache('u1').readList(), isNull);
    });
  });

  group('trip detail cache', () {
    test('round-trips a trip with a saved-at timestamp', () async {
      final cache = TripCache('u1');
      await cache.writeTrip(_trip('t1', title: 'Greece'));
      final cached = await cache.readTrip('t1');
      expect(cached, isNotNull);
      expect(cached!.trip.title, 'Greece');
      expect(await cache.readTrip('missing'), isNull);
    });

    test('evicts the least-recently-written beyond maxCachedTrips', () async {
      final cache = TripCache('u1');
      for (var i = 0; i < TripCache.maxCachedTrips + 2; i++) {
        await cache.writeTrip(_trip('t$i'));
      }
      // t0 and t1 evicted; the newest 10 remain.
      expect(await cache.readTrip('t0'), isNull);
      expect(await cache.readTrip('t1'), isNull);
      expect(await cache.readTrip('t2'), isNotNull);
      expect(await cache.readTrip('t${TripCache.maxCachedTrips + 1}'),
          isNotNull);
    });

    test('re-writing an existing trip bumps it to most-recent', () async {
      final cache = TripCache('u1');
      for (var i = 0; i < TripCache.maxCachedTrips; i++) {
        await cache.writeTrip(_trip('t$i'));
      }
      await cache.writeTrip(_trip('t0')); // refresh the oldest
      await cache.writeTrip(_trip('new')); // should evict t1, not t0
      expect(await cache.readTrip('t0'), isNotNull);
      expect(await cache.readTrip('t1'), isNull);
    });

    test('removeTrip drops the detail and the row in the cached list',
        () async {
      final cache = TripCache('u1');
      await cache.writeList([_trip('t1'), _trip('t2')]);
      await cache.writeTrip(_trip('t1'));
      await cache.removeTrip('t1');
      expect(await cache.readTrip('t1'), isNull);
      final list = await cache.readList();
      expect(list!.trips.map((t) => t.id), ['t2']);
    });
  });

  group('clearForUser (sign-out / account deletion)', () {
    test('removes every trip_cache key for that user only', () async {
      final cache = TripCache('u1');
      await cache.writeList([_trip('a')]);
      await cache.writeTrip(_trip('a'));
      await TripCache('u2').writeTrip(_trip('b'));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('recent_trip.u1', jsonEncode({'id': 'a'}));

      await TripCache.clearForUser('u1');

      expect(await TripCache('u1').readList(), isNull);
      expect(await TripCache('u1').readTrip('a'), isNull);
      expect(prefs.getKeys().where((k) => k.startsWith('trip_cache.u1.')),
          isEmpty);
      // Other users' caches and unrelated keys are untouched.
      expect(await TripCache('u2').readTrip('b'), isNotNull);
      expect(prefs.getString('recent_trip.u1'), isNotNull);
    });
  });
}
