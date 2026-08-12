import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

/// listTrips answers from a queue: a List<Trip> resolves, anything else
/// throws it.
class _QueuedTripsApiService extends TripsApiService {
  final List<Object> responses;
  int calls = 0;

  _QueuedTripsApiService(this.responses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() {
    final next =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (next is List<Trip>) return Future.value(next);
    return Future.error(next);
  }
}

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

  test('a successful load serves live data and writes through to the cache',
      () async {
    final cache = TripCache('u1');
    final notifier = TripsNotifier(
        _QueuedTripsApiService([
          [_trip('a', title: 'Athens')]
        ]),
        cache);

    await notifier.loadTrips();

    expect(notifier.state.trips.single.title, 'Athens');
    expect(notifier.state.offlineSince, isNull);
    expect(notifier.state.error, isNull);
    // Write-through is fire-and-forget; give the microtask a beat.
    await Future<void>.delayed(Duration.zero);
    final cached = await cache.readList();
    expect(cached!.trips.single.title, 'Athens');
  });

  test('a network error serves the cached copy, marked offline', () async {
    final cache = TripCache('u1');
    await cache.writeList([_trip('a', title: 'Athens')]);
    final notifier = TripsNotifier(
        _QueuedTripsApiService([http.ClientException('connection refused')]),
        cache);

    await notifier.loadTrips();

    expect(notifier.state.trips.single.title, 'Athens');
    expect(notifier.state.offlineSince, isNotNull);
    expect(notifier.state.error, isNull);
    expect(notifier.state.loading, isFalse);
  });

  test('an HTTP error (403) does NOT fall back to the cache', () async {
    final cache = TripCache('u1');
    await cache.writeList([_trip('a', title: 'Athens')]);
    final notifier = TripsNotifier(
        _QueuedTripsApiService([Exception('Failed to load trips (403)')]),
        cache);

    await notifier.loadTrips();

    expect(notifier.state.trips, isEmpty);
    expect(notifier.state.offlineSince, isNull);
    expect(notifier.state.error, contains('403'));
  });

  test('a network error with no cached copy keeps the normal error path',
      () async {
    final notifier = TripsNotifier(
        _QueuedTripsApiService([http.ClientException('connection refused')]),
        TripCache('u1'));

    await notifier.loadTrips();

    expect(notifier.state.trips, isEmpty);
    expect(notifier.state.offlineSince, isNull);
    expect(notifier.state.error, isNotNull);
  });

  test('a later successful load clears the offline marker', () async {
    final cache = TripCache('u1');
    await cache.writeList([_trip('a')]);
    final notifier = TripsNotifier(
        _QueuedTripsApiService([
          http.ClientException('down'),
          [_trip('a'), _trip('b')]
        ]),
        cache);

    await notifier.loadTrips();
    expect(notifier.state.offlineSince, isNotNull);

    await notifier.loadTrips();
    expect(notifier.state.offlineSince, isNull);
    expect(notifier.state.trips, hasLength(2));
  });
}
