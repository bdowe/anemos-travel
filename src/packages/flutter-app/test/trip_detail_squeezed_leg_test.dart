import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

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

Trip _trip(List<ItineraryItem> items, {List<Accommodation>? stays}) => Trip(
      id: 't1',
      title: 'Squeeze',
      status: 'planned',
      startDate: '2026-09-01',
      endDate: '2026-09-07',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items,
      accommodations: stays,
    );

Future<List<Map<String, dynamic>>> _pumpAndCapture(
    WidgetTester tester, Trip trip) async {
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
  return fake.syncedPayloads.last;
}

void main() {
  testWidgets(
      'a squeezed leg renders as a zero-night stop at its arrival, '
      'and downstream flight dates cascade', (WidgetTester tester) async {
    // Medellín ran through Sep 6 but Quito's single item still departs Sep 5
    // — the inverted interim state a set_leg_dates squeeze leaves behind.
    // Quito must read as a zero-night stop at the arrival (Sep 6), never a
    // check-in before the inbound flight lands.
    final derived = await _pumpAndCapture(
      tester,
      _trip([
        _item(0, 'Museo', 'Medellín', day: 1),
        _item(1, 'Comuna 13', 'Medellín', day: 6),
        _item(2, 'Quito', 'Quito', day: 5),
        _item(3, 'Mitad del Mundo', 'Galápagos', day: 6),
        _item(4, 'Tortuga Bay', 'Galápagos', day: 7),
      ]),
    );

    final quitoStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:quito');
    expect(quitoStay['depart_date'], '2026-09-06');
    expect(quitoStay['return_date'], '2026-09-06');
    expect(quitoStay['subtitle'], 'Sep 6');

    expect(
        derived.singleWhere(
            (t) => t['todo_key'] == 'transport:medellín>>quito')['depart_date'],
        '2026-09-06');
    // The cascade: the onward flight rides Quito's VISIBLE end, not its
    // stale raw departure day (Sep 5).
    expect(
        derived.singleWhere((t) =>
            t['todo_key'] == 'transport:quito>>galápagos')['depart_date'],
        '2026-09-06');

    final galStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:galápagos');
    expect(galStay['depart_date'], '2026-09-06');
    expect(galStay['return_date'], '2026-09-07');

    // Headers: no stale bare "Sep 5" chip anywhere; the squeezed leg shows
    // its bare arrival (zero nights -> no counter) and the next leg follows
    // from it with a night count.
    expect(find.text('Sep 5'), findsNothing);
    expect(find.text('Sep 6'), findsWidgets);
    expect(find.text('Sep 6 – Sep 7 · 1 night'), findsWidgets);
  });

  testWidgets('consecutive squeezed legs chain onto the same arrival',
      (WidgetTester tester) async {
    final derived = await _pumpAndCapture(
      tester,
      _trip([
        _item(0, 'Museo', 'Medellín', day: 1),
        _item(1, 'Comuna 13', 'Medellín', day: 6),
        _item(2, 'Quito', 'Quito', day: 4),
        _item(3, 'Guayaquil', 'Guayaquil', day: 5),
      ]),
    );

    for (final key in ['stay:quito', 'stay:guayaquil']) {
      final stay = derived.singleWhere((t) => t['todo_key'] == key);
      expect(stay['depart_date'], '2026-09-06', reason: key);
      expect(stay['return_date'], '2026-09-06', reason: key);
    }
    expect(
        derived.singleWhere(
            (t) => t['todo_key'] == 'transport:medellín>>quito')['depart_date'],
        '2026-09-06');
    expect(
        derived.singleWhere((t) =>
            t['todo_key'] == 'transport:quito>>guayaquil')['depart_date'],
        '2026-09-06');
    expect(find.text('Sep 4'), findsNothing);
    expect(find.text('Sep 5'), findsNothing);
  });

  testWidgets('a confirmed stay is never collapsed by the squeeze clamp',
      (WidgetTester tester) async {
    // Quito carries an explicit confirmed stay (Sep 3–5); even with Medellín
    // running through Sep 6, the traveler's own dates win.
    final derived = await _pumpAndCapture(
      tester,
      _trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 5),
        ],
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Quito',
            address: 'Av. González Suárez, Quito, Ecuador',
            checkIn: '2026-09-03',
            checkOut: '2026-09-05',
          ),
        ],
      ),
    );

    final quitoStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:quito');
    expect(quitoStay['depart_date'], '2026-09-03');
    expect(quitoStay['return_date'], '2026-09-05');
    expect(find.text('Sep 3 – Sep 5 · 2 nights'), findsWidgets);
  });
}
