import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// A trip can depart from one airport and come home into another — out of ALB,
/// home into EWR. The checklist's two home legs read from their OWN ladder
/// rung, so a departure-only change never rewrites the return.
///
/// Twin of the Go table in booking_todo_identity_test.go: these keys and titles
/// are what the server canonicalizes and relabels, so a divergence here is a
/// divergence there.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _CapturingBookingTodosApiService extends BookingTodosApiService {
  final List<List<Map<String, dynamic>>> syncedPayloads = [];
  _CapturingBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
      String tripId, List<Map<String, dynamic>> derived) async {
    syncedPayloads.add(derived);
    throw Exception('offline test env');
  }
}

class _FakePrefsApi implements PreferencesApiService {
  _FakePrefsApi(this.homeAirport);
  String homeAirport;
  int calls = 0;

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async {
    calls++;
    return TravelerPreferences(homeAirport: homeAirport);
  }

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
    String? fitnessRoutine,
    String? outdoorIntensity,
    String? companions,
  }) async =>
      TravelerPreferences(homeAirport: this.homeAirport);
}

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city address',
      // Zero coords so the screen skips the map widget in this env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

void main() {
  Trip makeTrip({String? origin, String? originAirport, String? returnAirport}) =>
      Trip(
        id: 't1',
        title: 'Amsterdam',
        startDate: '2026-08-24',
        endDate: '2026-08-28',
        createdAt: '2026-08-01',
        updatedAt: '2026-08-01',
        origin: origin,
        originAirport: originAirport,
        returnAirport: returnAirport,
        items: [
          _item(0, 'Rijksmuseum', 'Amsterdam', day: 1),
          _item(1, 'Anne Frank House', 'Amsterdam', day: 4),
        ],
      );

  Future<List<Map<String, dynamic>>> derive(
    WidgetTester tester,
    Trip trip, {
    _FakePrefsApi? prefs,
  }) async {
    final fake = _CapturingBookingTodosApiService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider.overrideWithValue(fake),
          preferencesApiServiceProvider
              .overrideWithValue(prefs ?? _FakePrefsApi('EWR')),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.syncedPayloads, isNotEmpty);
    // The prefs load is async and can re-trigger the derivation; the last
    // payload is the one that saw the loaded home airport.
    return fake.syncedPayloads.last;
  }

  Map<String, dynamic> legNamed(List<Map<String, dynamic>> derived, String key) =>
      derived.singleWhere((t) => t['todo_key'] == key);

  testWidgets('with no trip airport, both legs use the saved home airport',
      (WidgetTester tester) async {
    final derived = await derive(tester, makeTrip());

    expect(legNamed(derived, 'transport:ewr>>amsterdam')['title'],
        'EWR → Amsterdam');
    expect(legNamed(derived, 'transport:amsterdam>>ewr')['title'],
        'Amsterdam → EWR');
  });

  testWidgets("the trip's own airport outranks the saved one, both directions",
      (WidgetTester tester) async {
    final derived = await derive(
      tester,
      makeTrip(originAirport: 'ALB', returnAirport: 'ALB'),
    );

    expect(legNamed(derived, 'transport:alb>>amsterdam')['title'],
        'ALB → Amsterdam');
    expect(legNamed(derived, 'transport:amsterdam>>alb')['title'],
        'Amsterdam → ALB');
    expect(derived.where((t) => (t['todo_key'] as String).contains('ewr')),
        isEmpty);
  });

  testWidgets('departing and returning through different airports',
      (WidgetTester tester) async {
    // The reported trip: out of ALB, home into EWR.
    final derived = await derive(
      tester,
      makeTrip(originAirport: 'ALB', returnAirport: 'EWR'),
    );

    expect(legNamed(derived, 'transport:alb>>amsterdam')['title'],
        'ALB → Amsterdam');
    expect(legNamed(derived, 'transport:amsterdam>>ewr')['title'],
        'Amsterdam → EWR');
  });

  testWidgets('an origin stated in words still titles both legs',
      (WidgetTester tester) async {
    // No airport, so the free text is the label — verbatim, the way the
    // traveler said it.
    final derived = await derive(tester, makeTrip(origin: 'Lake George, NY'));

    expect(legNamed(derived, 'transport:lake george, ny>>amsterdam')['title'],
        'Lake George, NY → Amsterdam');
  });

  testWidgets('a home airport changed mid-session reaches an open trip page',
      (WidgetTester tester) async {
    // The agent can write the saved home airport (save_preferences) while the
    // trip page is open. Before, loadIfNeeded's cached copy meant the page kept
    // deriving EWR until an app restart; the plan stream now calls load() when
    // profile_updated names a field, and the screen mirrors the change.
    final prefs = _FakePrefsApi('EWR');
    final fake = _CapturingBookingTodosApiService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_FakeTripsApiService(makeTrip())),
          bookingTodosApiServiceProvider.overrideWithValue(fake),
          preferencesApiServiceProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.syncedPayloads.last.map((t) => t['todo_key']),
        contains('transport:ewr>>amsterdam'));

    // What the plan stream does on profile_updated: a real re-read, not the
    // cache check.
    prefs.homeAirport = 'ALB';
    final element = tester.element(find.byType(TripDetailScreen));
    await ProviderScope.containerOf(element)
        .read(preferencesProvider.notifier)
        .load();
    await tester.pumpAndSettle();

    expect(fake.syncedPayloads.last.map((t) => t['todo_key']),
        contains('transport:alb>>amsterdam'));
  });
}
