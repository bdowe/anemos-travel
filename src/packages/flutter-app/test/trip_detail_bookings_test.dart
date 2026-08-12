import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/accommodations_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path. The booking-todo sync call fails in the
/// test env and is swallowed, so the todos seeded on the trip survive.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

ItineraryItem _item(int pos, String name, String address, String category,
        {int? day, String? city}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: address,
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: category,
      day: day,
      city: city,
    );

BookingTodo _todo(String kind, String key, String title,
        {bool auto = true, String? departDate, String? returnDate}) =>
    BookingTodo(
        id: key,
        kind: kind,
        todoKey: key,
        title: title,
        auto: auto,
        departDate: departDate,
        returnDate: returnDate);

class _FakeAccommodationsApiService extends AccommodationsApiService {
  final List<Map<String, dynamic>> added = [];
  _FakeAccommodationsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Accommodation> add(String tripId, Map<String, dynamic> body) async {
    added.add(body);
    return const Accommodation(id: 'new', name: 'Stay');
  }
}

/// The itinerary renders lazily (slivers), so widgets below the default
/// 800x600 test viewport never get built. A tall viewport keeps the whole
/// page — including the trailing bookings section — built and findable.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('city-matched bookings embed in their group; rest are residual',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final trip = Trip(
      id: 't1',
      title: 'Europe',
      status: 'planned',
      startDate: '2026-06-10',
      endDate: '2026-06-13',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', 'Paris, France', 'attraction',
            day: 1, city: 'Paris'),
        _item(1, 'Café de Flore', 'Paris, France', 'restaurant',
            day: 2, city: 'Paris'),
        _item(2, 'Colosseum', 'Rome, Italy', 'attraction',
            day: 3, city: 'Rome'),
        _item(3, 'Trastevere', 'Rome, Italy', 'restaurant',
            day: 4, city: 'Rome'),
      ],
      bookingTodos: [
        _todo('transport', 'transport:jfk>>paris', 'JFK → Paris'),
        _todo('stay', 'stay:paris', 'Stay in Paris'),
        _todo('transport', 'transport:paris>>rome', 'Paris → Rome'),
        _todo('stay', 'stay:rome', 'Stay in Rome'),
        _todo('transport', 'transport:rome>>jfk', 'Rome → JFK'),
        _todo('other', 'custom:x', 'Museum tickets', auto: false),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Groups default collapsed, and the accordion contract allows at most ONE
    // open city at a time (expanding a city closes the previous one), so each
    // city's embedded rows are asserted while that city is the open group.
    // Headers, the tab counter, and Other bookings render regardless.

    // Paris open: its city-matched bookings render once each, as compact
    // embedded rows, with arrival + stay above the city's first item.
    await expandCity(tester, 'Paris');
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'JFK → Paris'), findsOneWidget);
    expect(tester.getTopLeft(find.text('JFK → Paris')).dy,
        lessThan(tester.getTopLeft(find.text('Louvre')).dy));

    // Rome open (Paris closes): 'Paris → Rome' is Rome's ARRIVAL row, so it
    // renders inside Rome's group above Rome's first item; the return flight
    // home comes after the last city's last item.
    await expandCity(tester, 'Rome');
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Paris → Rome'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Rome → JFK'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Paris → Rome')).dy,
        lessThan(tester.getTopLeft(find.text('Colosseum')).dy));
    expect(tester.getTopLeft(find.text('Rome → JFK')).dy,
        greaterThan(tester.getTopLeft(find.text('Trastevere')).dy));

    // The separate Bookings section is retired; the header's Bookings tab
    // carries the booking progress in its label instead.
    expect(find.text('Bookings · 0/6'), findsOneWidget);

    // Only the unmatched custom todo lands in the "Other bookings" area at
    // the itinerary's tail, as a card — directly visible, no expand step.
    await tester.ensureVisible(find.text('Other bookings'));
    expect(find.byType(BookingTodoCard), findsOneWidget);
    expect(
        find.widgetWithText(BookingTodoCard, 'Museum tickets'), findsOneWidget);
  });

  testWidgets('collapsing a city hides its embedded booking rows',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final trip = Trip(
      id: 't2',
      title: 'Weekend away',
      status: 'planned',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', 'Paris, France', 'attraction',
            day: 1, city: 'Paris'),
      ],
      bookingTodos: [
        _todo('transport', 'transport:jfk>>paris', 'JFK → Paris'),
        _todo('stay', 'stay:paris', 'Stay in Paris'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't2')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BookingTodoRow), findsNWidgets(2));

    // No unmatched bookings -> no "Other bookings" sub-header, just the
    // always-available add actions at the itinerary's tail.
    expect(find.text('Other bookings'), findsNothing);
    expect(find.text('Add booking'), findsOneWidget);

    await tester.ensureVisible(find.text('Paris'));
    await tester.tap(find.text('Paris'));
    await tester.pumpAndSettle();

    expect(find.byType(BookingTodoRow), findsNothing);
    expect(find.text('Louvre'), findsNothing);
  });

  testWidgets(
      'Add details… promotes a stay todo to a confirmed record, prefilled',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final accommodations = _FakeAccommodationsApiService();
    final trip = Trip(
      id: 't3',
      title: 'Weekend away',
      status: 'planned',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', 'Paris, France', 'attraction',
            day: 1, city: 'Paris'),
      ],
      bookingTodos: [
        _todo('stay', 'stay:paris', 'Stay in Paris',
            departDate: '2026-06-10', returnDate: '2026-06-12'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          accommodationsApiServiceProvider.overrideWithValue(accommodations),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't3')),
      ),
    );
    await tester.pumpAndSettle();

    // The inline row carries the promotion kebab; open it.
    final kebab = find.descendant(
        of: find.byType(BookingTodoRow), matching: find.byIcon(Icons.more_vert));
    expect(kebab, findsOneWidget);
    await tester.tap(kebab);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add details…'));
    await tester.pumpAndSettle();

    // The stay sheet opens in ADD mode, prefilled from the todo.
    expect(find.text('Add a stay'), findsOneWidget);
    expect(find.text('Stay in Paris'), findsWidgets); // row + prefilled field
    expect(find.text('2026-06-10 → 2026-06-12'), findsWidgets);

    // Saving POSTs a normal confirmed accommodation.
    await tester.tap(find.widgetWithText(FilledButton, 'Add stay'));
    await tester.pumpAndSettle();
    expect(accommodations.added, hasLength(1));
    expect(accommodations.added.single['name'], 'Stay in Paris');
    expect(accommodations.added.single['check_in'], '2026-06-10');
    expect(accommodations.added.single['check_out'], '2026-06-12');
  });
}
