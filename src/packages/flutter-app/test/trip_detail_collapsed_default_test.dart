import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

/// Destination groups default to COLLAPSED: the resting view is one
/// place-plus-dates header line per destination. Only a sole group is seeded
/// open, and today-mode force-expands today's group on live trips.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  int calls = 0;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    calls++;
    return trip;
  }
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

ItineraryItem _item(int pos, String name, String? city, int day,
        {String? address = 'somewhere'}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: city == null ? address : '$name street, $city, Country',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Future<_FakeTripsApiService> _pump(WidgetTester tester, Trip trip) async {
  final service = _FakeTripsApiService(trip);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  Trip twoCityTrip() => Trip(
        id: 't1',
        title: 'Europe',
        status: 'planned',
        startDate: '2026-06-10',
        endDate: '2026-06-12',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        items: [
          _item(0, 'Louvre', 'Paris', 1),
          _item(1, 'Colosseum', 'Rome', 2),
        ],
        bookingTodos: const [
          BookingTodo(
              id: 'td-stay',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris'),
        ],
      );

  testWidgets('destination groups start collapsed: headers and dates only',
      (WidgetTester tester) async {
    await _pump(tester, twoCityTrip());

    // Headers with their date ranges are the whole resting view.
    expect(find.text('Paris'), findsOneWidget);
    expect(find.text('Rome'), findsOneWidget);
    expect(find.text('Jun 10 – Jun 11'), findsOneWidget);

    // Items and embedded booking rows are hidden until a group is opened.
    expect(find.text('Louvre'), findsNothing);
    expect(find.text('Colosseum'), findsNothing);
    expect(find.byType(BookingTodoRow), findsNothing);
  });

  testWidgets('a header tap expands only that group, and toggles back',
      (WidgetTester tester) async {
    await _pump(tester, twoCityTrip());

    await expandCity(tester, 'Paris');
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        findsOneWidget);
    expect(find.text('Colosseum'), findsNothing);

    await tester.tap(find.text('Paris'));
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsNothing);
    expect(find.byType(BookingTodoRow), findsNothing);
  });

  testWidgets('a single-destination trip is seeded open',
      (WidgetTester tester) async {
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Getaway',
          status: 'planned',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: [
            _item(0, 'Louvre', 'Paris', 1),
            _item(1, 'Orsay', 'Paris', 1),
          ],
        ));

    // One group: collapsed-to-one-line would be an empty screen, so the
    // sole group opens by default (and stays collapsible).
    expect(find.text('Louvre'), findsOneWidget);
    await tester.tap(find.text('Paris'));
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsNothing);
  });

  testWidgets('a sole Other-places group is seeded open too',
      (WidgetTester tester) async {
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Mystery',
          status: 'planned',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: [
            _item(0, 'Hidden gem', null, 1, address: null),
            _item(1, 'Second stop', null, 1, address: null),
          ],
        ));

    expect(find.text('Other places'), findsOneWidget);
    expect(find.text('Hidden gem'), findsOneWidget);
  });

  testWidgets('expansion survives a silent refresh; the seed stays one-shot',
      (WidgetTester tester) async {
    final service = await _pump(tester, twoCityTrip());

    await expandCity(tester, 'Paris');
    expect(find.text('Louvre'), findsOneWidget);

    // Pull-to-refresh really refetches (the fake counts calls) without
    // resetting the user's expansion — and without the sole-group seed
    // re-firing to open anything on a multi-group trip.
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(service.calls, greaterThan(1));
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Colosseum'), findsNothing);
  });

  testWidgets(
      'cold start on a live trip auto-expands only today\'s collapsed group',
      (WidgetTester tester) async {
    // Today is day 2 of a 3-day trip that started yesterday; day 1 is a
    // different city, so today's group starts collapsed two groups deep.
    final now = DateTime.now();
    final trip = Trip(
      id: 't1',
      title: 'Live Trip',
      status: 'planned',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: _iso(now.subtract(const Duration(days: 1))),
      endDate: _iso(now.add(const Duration(days: 1))),
      items: [
        for (var k = 0; k < 6; k++) _item(k, 'Past stop $k', 'Paris', 1),
        for (var k = 0; k < 6; k++) _item(6 + k, 'Today stop $k', 'Rome', 2),
        for (var k = 0; k < 4; k++) _item(12 + k, 'Next stop $k', 'Rome', 3),
      ],
    );
    await _pump(tester, trip);

    // The one-shot auto-scroll expanded Rome (never rendered before — its
    // day keys come from the build-time registry, not built headers) and
    // landed on today's header; Paris stayed collapsed.
    expect(_position(tester).pixels, greaterThan(0));
    expect(find.text('Today stop 0'), findsOneWidget);
    expect(find.widgetWithText(StatusPill, 'Today'), findsOneWidget);
    expect(find.text('Past stop 0'), findsNothing);

    // The Today jump chip re-expands after a manual collapse of the CITY
    // (not just the day): collapse Rome, park at the top, jump.
    await tester.tap(find.text('Rome'));
    await tester.pumpAndSettle();
    expect(find.text('Today stop 0'), findsNothing);
    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ActionChip, 'Today'));
    await tester.pumpAndSettle();
    expect(find.text('Today stop 0'), findsOneWidget);
    expect(find.text('Past stop 0'), findsNothing);
    expect(_position(tester).pixels, greaterThan(0));
  });
}
