import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/airport.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/flights_api_service.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';

/// Self-heal semantics for the two providers a transient boot-time failure
/// used to pin for the whole session (neither family is autoDispose):
/// a transient error arms a one-shot 30s invalidateSelf; a stable error
/// (404) and a confirmed-empty success stay cached with no retry traffic.

class _ScriptedFlightsApi extends FlightsApiService {
  final List<Object> script; // List<Airport> resolves, anything else throws.
  int calls = 0;
  _ScriptedFlightsApi(this.script) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Airport>> searchAirports(String query) {
    final next = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (next is List<Airport>) return Future.value(next);
    return Future.error(next);
  }
}

class _ScriptedReviewApi extends TripReviewApiService {
  final List<Object> script;
  int calls = 0;
  _ScriptedReviewApi(this.script) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripReview> getReview(String tripId,
      {bool checkHours = false}) {
    final next = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (next is List<TripFinding>) {
      return Future.value(TripReview(findings: next));
    }
    return Future.error(next);
  }
}

const _lax = Airport(
    iataCode: 'LAX',
    name: 'Los Angeles International',
    subType: 'airport',
    latitude: 33.9425,
    longitude: -118.408);

ApiException _ex(int status) =>
    ApiException(statusCode: status, message: 'x', endpoint: 'x');

void main() {
  group('homeAirportPointProvider', () {
    test('transient error self-heals: refetches 30s later while watched', () {
      fakeAsync((async) {
        final api = _ScriptedFlightsApi([
          _ex(429),
          const [_lax],
        ]);
        final container = ProviderContainer(overrides: [
          flightsApiServiceProvider.overrideWithValue(api),
        ]);
        addTearDown(container.dispose);
        container.listen(homeAirportPointProvider('LAX'), (_, __) {});
        async.flushMicrotasks();

        expect(container.read(homeAirportPointProvider('LAX')).hasError,
            isTrue);
        expect(api.calls, 1);

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        final healed = container.read(homeAirportPointProvider('LAX'));
        expect(api.calls, 2);
        expect(healed.value, isNotNull);
        expect(healed.value!.lat, 33.9425);
      });
    });

    test('stable error (404) is cached — no retry timer', () {
      fakeAsync((async) {
        final api = _ScriptedFlightsApi([_ex(404)]);
        final container = ProviderContainer(overrides: [
          flightsApiServiceProvider.overrideWithValue(api),
        ]);
        addTearDown(container.dispose);
        container.listen(homeAirportPointProvider('LAX'), (_, __) {});
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();

        expect(api.calls, 1, reason: 'no self-heal for stable errors');
        expect(container.read(homeAirportPointProvider('LAX')).hasError,
            isTrue);
      });
    });

    test('confirmed-empty success caches null with no retry traffic', () {
      fakeAsync((async) {
        final api = _ScriptedFlightsApi([const <Airport>[]]);
        final container = ProviderContainer(overrides: [
          flightsApiServiceProvider.overrideWithValue(api),
        ]);
        addTearDown(container.dispose);
        container.listen(homeAirportPointProvider('LAX'), (_, __) {});
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();

        final v = container.read(homeAirportPointProvider('LAX'));
        expect(v.hasValue, isTrue);
        expect(v.value, isNull, reason: 'no coordinates → confirmed empty');
        expect(api.calls, 1);
      });
    });
  });

  group('tripReviewProvider', () {
    test('503 self-invalidates and recovers 30s later', () {
      fakeAsync((async) {
        final api = _ScriptedReviewApi([
          _ex(503),
          const <TripFinding>[],
        ]);
        final container = ProviderContainer(overrides: [
          tripReviewApiServiceProvider.overrideWithValue(api),
        ]);
        addTearDown(container.dispose);
        const key = TripReviewKey('t1');
        container.listen(tripReviewProvider(key), (_, __) {});
        async.flushMicrotasks();

        expect(container.read(tripReviewProvider(key)).hasError, isTrue);

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        expect(api.calls, 2);
        expect(container.read(tripReviewProvider(key)).hasValue, isTrue);
      });
    });

    test('the viewer 404 stays a stable cached error', () {
      fakeAsync((async) {
        final api = _ScriptedReviewApi([_ex(404)]);
        final container = ProviderContainer(overrides: [
          tripReviewApiServiceProvider.overrideWithValue(api),
        ]);
        addTearDown(container.dispose);
        const key = TripReviewKey('t1');
        container.listen(tripReviewProvider(key), (_, __) {});
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();

        expect(api.calls, 1);
        expect(container.read(tripReviewProvider(key)).hasError, isTrue);
      });
    });
  });
}
