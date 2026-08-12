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

import 'support/chip_finders.dart';
import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path (and its booking-todo derivation).
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Records the derived payload the screen tries to sync, then fails like the
/// offline test env (the screen swallows the error).
class _CapturingBookingTodosApiService extends BookingTodosApiService {
  final List<List<Map<String, dynamic>>> syncedPayloads = [];
  _CapturingBookingTodosApiService()
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
      String tripId, List<Map<String, dynamic>> derived) async {
    syncedPayloads.add(derived);
    throw Exception('offline test env');
  }
}

class _FakePrefsApi implements PreferencesApiService {
  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async =>
      const TravelerPreferences(homeAirport: 'EWR');

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
  }) async =>
      const TravelerPreferences(homeAirport: 'EWR');
}

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city address',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

void main() {
  testWidgets(
      'stay dates start at the arrival into the city, not its first item day',
      (WidgetTester tester) async {
    // Gothenburg spans days 1–3 (Aug 24–26); Madrid has a single item on day 5
    // (Aug 28), so its derived range collapses to that one day. The leg into
    // Madrid departs on Gothenburg's end (Aug 26) — the stay must start there
    // too, not read as a bare "Aug 28".
    final trip = Trip(
      id: 't1',
      title: 'Iberia',
      startDate: '2026-08-24',
      endDate: '2026-08-28',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
        _item(1, 'Liseberg', 'Gothenburg', day: 3),
        _item(2, 'Prado', 'Madrid', day: 5),
      ],
    );

    final fake = _CapturingBookingTodosApiService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(fake.syncedPayloads, isNotEmpty);
    final derived = fake.syncedPayloads.first;

    final madridStay = derived.singleWhere((t) => t['todo_key'] == 'stay:madrid');
    expect(madridStay['subtitle'], 'Aug 26 – Aug 28');
    expect(madridStay['depart_date'], '2026-08-26');
    expect(madridStay['return_date'], '2026-08-28');

    // The inbound leg carries the same departure date as the stay's check-in.
    final leg = derived
        .singleWhere((t) => t['todo_key'] == 'transport:gothenburg>>madrid');
    expect(leg['depart_date'], '2026-08-26');

    // The first city is anchored to the trip start — here its day-1 range
    // already begins there, so the anchor is a no-op.
    final gothenburgStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:gothenburg');
    expect(gothenburgStay['subtitle'], 'Aug 24 – Aug 26');
    expect(gothenburgStay['depart_date'], '2026-08-24');
  });

  testWidgets(
      'first leg anchors to the trip start when its items sit on a late day',
      (WidgetTester tester) async {
    // Prague's single item is on day 4 (Aug 27) of an Aug 24 trip — the
    // shape a set_leg_dates boundary extension leaves behind. The traveler
    // is in Prague from the trip's first day, so the header, stay todo, and
    // the EWR home leg must all read from Aug 24, never a bare "Aug 27".
    final trip = Trip(
      id: 't1',
      title: 'Big Summer',
      startDate: '2026-08-24',
      endDate: '2026-09-01',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Prague', 'Prague', day: 4),
        _item(1, 'Kraków', 'Kraków', day: 9),
      ],
    );

    final fake = _CapturingBookingTodosApiService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider.overrideWithValue(fake),
          preferencesApiServiceProvider.overrideWithValue(_FakePrefsApi()),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Header shows the anchored range with its night count, not a bare
    // end date.
    // Scoped to Prague's row: the count must sit in the SAME chip as the
    // anchored range (nights from the same visibleLegRanges pair).
    expect(chipTextIn('Prague', 'Aug 24 – Aug 27'), findsOneWidget);
    expect(chipTextIn('Prague', '· 3 nights'), findsOneWidget);
    expect(find.text('Aug 27'), findsNothing);

    // The prefs load is async and can re-trigger the derivation — assert on
    // the last synced payload, which reflects the loaded home airport.
    expect(fake.syncedPayloads, isNotEmpty);
    final derived = fake.syncedPayloads.last;

    final pragueStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:prague');
    expect(pragueStay['subtitle'], 'Aug 24 – Aug 27');
    expect(pragueStay['depart_date'], '2026-08-24');
    expect(pragueStay['return_date'], '2026-08-27');

    final homeLeg =
        derived.singleWhere((t) => t['todo_key'] == 'transport:ewr>>prague');
    expect(homeLeg['title'], 'EWR → Prague');
    expect(homeLeg['depart_date'], '2026-08-24');

    // The second city's arrival stays the previous leg's end — the i>0
    // arrival logic is untouched by the anchor.
    final krakowStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:kraków');
    expect(krakowStay['depart_date'], '2026-08-27');
  });

  testWidgets(
      'city header range is arrival-adjusted like the stay todos',
      (WidgetTester tester) async {
    // Same collapsed-leg shape: Madrid's one item sits on day 5 (Aug 28), so
    // its raw range is that single day. The header must read from the arrival
    // (Gothenburg's end, Aug 26) — a bare "Aug 28" chip would contradict the
    // stay row right beneath it.
    final trip = Trip(
      id: 't1',
      title: 'Iberia',
      startDate: '2026-08-24',
      endDate: '2026-08-28',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
        _item(1, 'Liseberg', 'Gothenburg', day: 3),
        _item(2, 'Prado', 'Madrid', day: 5),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider
              .overrideWithValue(_CapturingBookingTodosApiService()),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Scoped to Madrid's row — Gothenburg is ALSO 2 nights, so a global
    // find would be satisfied by the wrong chip.
    expect(chipTextIn('Madrid', 'Aug 26 – Aug 28'), findsOneWidget);
    expect(chipTextIn('Madrid', '· 2 nights'), findsOneWidget);
    expect(find.text('Aug 28'), findsNothing);
  });
}
