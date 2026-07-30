import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/import_trip_result.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/import_trip_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/auth_storage.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

/// Import flow state machine (specs/import-trip-from-ai-chat): success carries
/// the result and refreshes the trips list; a server 422 surfaces its
/// localized message; unexpected failures fall back to the generic-error state.
class _FakeTripsApiService extends TripsApiService {
  final Object? importError;
  int listCalls = 0;
  String? importedText;

  _FakeTripsApiService({this.importError})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async {
    listCalls++;
    return const [];
  }

  @override
  Future<ImportTripResult> importTrip(String text, {String? source}) async {
    importedText = text;
    final err = importError;
    if (err != null) throw err;
    return const ImportTripResult(
      tripId: 'trip-1',
      title: 'Lisbon Weekend',
      itemCount: 3,
      warnings: ['Mystery Bar: location is approximate'],
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

void main() {
  test('successful import returns result and reloads trips', () async {
    final fake = _FakeTripsApiService();
    final container = _container(fake);

    final res = await container
        .read(importTripProvider.notifier)
        .import('Day 1: Belém Tower…');

    expect(res, isNotNull);
    expect(res!.tripId, 'trip-1');
    expect(res.warnings, hasLength(1));
    expect(fake.importedText, 'Day 1: Belém Tower…');
    expect(fake.listCalls, 1, reason: 'trips list must refresh on success');

    final state = container.read(importTripProvider);
    expect(state.importing, isFalse);
    expect(state.result?.tripId, 'trip-1');
    expect(state.error, isNull);
  });

  test('server 422 surfaces its localized message', () async {
    final fake = _FakeTripsApiService(
      importError: const ImportTripException(
          statusCode: 422, message: 'No encontramos un viaje en ese texto'),
    );
    final container = _container(fake);

    final res =
        await container.read(importTripProvider.notifier).import('recipe');

    expect(res, isNull);
    final state = container.read(importTripProvider);
    expect(state.error, 'No encontramos un viaje en ese texto');
    expect(state.result, isNull);
    expect(fake.listCalls, 0);
  });

  test('unexpected failure falls back to the generic-error state', () async {
    final fake = _FakeTripsApiService(importError: Exception('boom'));
    final container = _container(fake);

    final res =
        await container.read(importTripProvider.notifier).import('a plan');

    expect(res, isNull);
    expect(container.read(importTripProvider).error, isEmpty,
        reason: 'empty message means "show the generic copy"');
  });
}
