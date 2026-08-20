import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

// Screen-level wiring for the trip calendar sheet (the calendar icon in the
// pinned tab row): opens the sheet, and a day tap closes it and hands the
// trip day to the Today chip's _scrollToDay. The grid itself is covered by
// trip_calendar_sheet_test.dart.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Swallows the derived-payload sync like the offline test env.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');
}

ItineraryItem _item(int pos, String name, String city, int day) =>
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

/// Athens days 1–3, Kraków days 4–14: Aug 24 – Sep 6, 2026.
Trip _datedTrip() => Trip(
      id: 't1',
      title: 'Greece & Poland',
      startDate: '2026-08-24',
      endDate: '2026-09-06',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Acropolis', 'Athens', 1),
        _item(1, 'Plaka', 'Athens', 2),
        _item(2, 'Syntagma', 'Athens', 3),
        _item(3, 'Rynek Główny', 'Kraków', 4),
        _item(4, 'Wawel', 'Kraków', 5),
      ],
    );

Trip _undatedTrip() => Trip(
      id: 't1',
      title: 'Someday',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [_item(0, 'Acropolis', 'Athens', 1)],
    );

Future<void> _pump(WidgetTester tester, Trip trip) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
      ],
      child: localizedTestApp(home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the calendar icon opens the sheet over the trip\'s legs',
      (tester) async {
    await _pump(tester, _datedTrip());

    expect(find.byIcon(Icons.calendar_month_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Trip calendar'), findsOneWidget);
    expect(find.text('Aug 24 – Sep 6 · 14 days · 2 cities'), findsOneWidget);
    expect(find.text('Athens'), findsWidgets);
    expect(find.text('Kraków'), findsWidgets);
  });

  testWidgets('tapping a day closes the sheet and stays on the itinerary',
      (tester) async {
    await _pump(tester, _datedTrip());

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('trip-calendar-day-2026-08-24')));
    await tester.pumpAndSettle();

    expect(find.text('Trip calendar'), findsNothing);
    // The jump resolves through the Today chip's mechanism: the itinerary
    // list (its day headers) is still what renders.
    expect(find.text('Mon, Aug 24'), findsWidgets);
  });

  testWidgets('an undated trip has no calendar entry', (tester) async {
    await _pump(tester, _undatedTrip());

    expect(find.byIcon(Icons.calendar_month_outlined), findsNothing);
  });
}
