import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
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
      status: 'planned',
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

    // The first city keeps its own range untouched.
    final gothenburgStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:gothenburg');
    expect(gothenburgStay['subtitle'], 'Aug 24 – Aug 26');
    expect(gothenburgStay['depart_date'], '2026-08-24');
  });
}
