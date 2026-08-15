import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/log_trip_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/auth_storage.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

/// Log-a-past-trip state machine (specs/log-past-trip): a save returns the new
/// trip and refreshes the list (so "Your travels" is current when the user
/// lands back on it); the 422 trip-cap message is shown verbatim; everything
/// else falls back to the generic copy.
class _FakeTripsApiService extends TripsApiService {
  final Object? createError;
  int listCalls = 0;
  Map<String, dynamic>? sentBody;

  _FakeTripsApiService({this.createError})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async {
    listCalls++;
    return const [];
  }

  @override
  Future<Trip> createTrip({
    required List<Map<String, dynamic>> destinations,
    required String startDate,
    required String endDate,
    String? title,
  }) async {
    sentBody = {
      'destinations': destinations,
      'start_date': startDate,
      'end_date': endDate,
      'title': title,
    };
    final err = createError;
    if (err != null) throw err;
    return Trip(
      id: 'trip-1',
      title: title?.isNotEmpty == true ? title! : 'Trip to Kyoto',
      startDate: startDate,
      endDate: endDate,
      createdAt: '2026-08-14',
      updatedAt: '2026-08-14',
    );
  }
}

/// tripsProvider -> tripCacheProvider -> authProvider reaches secure storage's
/// platform channel; the in-memory storage keeps the container test pure.
class _FakeAuthStorage extends AuthStorage {
  String? token;

  @override
  Future<String?> loadToken() async => token;

  @override
  Future<void> saveToken(String value) async => token = value;

  @override
  Future<void> clearToken() async => token = null;
}

ProviderContainer _container(_FakeTripsApiService fake) {
  final container = ProviderContainer(overrides: [
    tripsApiServiceProvider.overrideWithValue(fake),
    authStorageProvider.overrideWithValue(_FakeAuthStorage()),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<Trip?> _save(ProviderContainer c, {String? title}) =>
    c.read(logTripProvider.notifier).save(
      destinations: [
        {
          'name': 'Kyoto',
          'place_id': 'pid-kyoto',
          'latitude': 35.0116,
          'longitude': 135.7681,
        },
        {'name': "Grandma's village"},
      ],
      startDate: '2019-03-03',
      endDate: '2019-03-17',
      title: title,
    );

void main() {
  test('successful save returns the trip and reloads the list', () async {
    final fake = _FakeTripsApiService();
    final container = _container(fake);

    final trip = await _save(container, title: 'Japan 2019');

    expect(trip, isNotNull);
    expect(trip!.id, 'trip-1');
    expect(fake.listCalls, 1,
        reason: 'the trips list — and Your travels with it — must refresh');

    final sent = fake.sentBody!;
    expect(sent['start_date'], '2019-03-03');
    expect(sent['end_date'], '2019-03-17');
    final destinations = sent['destinations'] as List<Map<String, dynamic>>;
    expect(destinations, hasLength(2));
    expect(destinations[0]['name'], 'Kyoto');
    expect(destinations[0]['latitude'], 35.0116);
    // Coordinates are never invented for a typed-name destination.
    expect(destinations[1].containsKey('latitude'), isFalse);

    final state = container.read(logTripProvider);
    expect(state.saving, isFalse);
    expect(state.error, isNull);
  });

  test('server 422 (trip cap) surfaces its message verbatim', () async {
    final fake = _FakeTripsApiService(
      createError: const CreateTripException(
          statusCode: 422,
          message: 'trip limit reached (200 trips) — delete an old trip first'),
    );
    final container = _container(fake);

    final trip = await _save(container);

    expect(trip, isNull);
    expect(container.read(logTripProvider).error,
        'trip limit reached (200 trips) — delete an old trip first');
    expect(fake.listCalls, 0);
  });

  test('a 400 is a client bug, not copy for the traveler', () async {
    final fake = _FakeTripsApiService(
      createError: const CreateTripException(
          statusCode: 400, message: 'end_date must not be before start_date'),
    );
    final container = _container(fake);

    await _save(container);

    expect(container.read(logTripProvider).error, isEmpty,
        reason: 'empty message means "show the generic copy"');
  });

  test('unexpected failure falls back to the generic-error state', () async {
    final fake = _FakeTripsApiService(createError: Exception('boom'));
    final container = _container(fake);

    final trip = await _save(container);

    expect(trip, isNull);
    expect(container.read(logTripProvider).error, isEmpty);
  });
}
