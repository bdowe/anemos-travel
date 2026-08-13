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

import 'support/chip_finders.dart';
import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

/// Destination groups default to EXPANDED: landing shows the whole
/// itinerary. Collapse is list-only session state (a Set of collapsed run
/// keys, decoupled from map focus) and a header tap toggles exactly ONE
/// group — there is no single-open accordion and no sole-group seed.
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

  testWidgets('destination groups start expanded',
      (WidgetTester tester) async {
    // Tall surface: with everything expanded, Rome's item tile sits past
    // the default 600px viewport's cache extent and would never build
    // (lazy SliverList).
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester, twoCityTrip());

    // Headers still lead each group with their date ranges.
    expect(find.text('Paris'), findsOneWidget);
    expect(find.text('Rome'), findsOneWidget);
    // Scoping revealed what the old global finder hid: the counted range
    // belongs to ROME (Paris's single day-1 item makes it a zero-night leg
    // with a bare date chip).
    expect(chipTextIn('Paris', 'Jun 10'), findsOneWidget);
    expect(chipTextIn('Rome', 'Jun 10 – Jun 11'), findsOneWidget);
    expect(chipTextIn('Rome', '· 1 night'), findsOneWidget);

    // Every group's items and embedded booking rows are visible on landing
    // — no expand step.
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Colosseum'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        findsOneWidget);
  });

  testWidgets('a header tap collapses only that group, and toggles back',
      (WidgetTester tester) async {
    // Tall surface for the same lazy-build reason as the landing test.
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester, twoCityTrip());

    await collapseCity(tester, 'Paris');
    expect(find.text('Louvre'), findsNothing);
    expect(find.byType(BookingTodoRow), findsNothing);
    // Other groups are untouched — no single-open accordion.
    expect(find.text('Colosseum'), findsOneWidget);

    await toggleCity(tester, 'Paris');
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        findsOneWidget);
    expect(find.text('Colosseum'), findsOneWidget);
  });

  testWidgets('a sole group still collapses and re-expands',
      (WidgetTester tester) async {
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Getaway',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: [
            _item(0, 'Louvre', 'Paris', 1),
            _item(1, 'Orsay', 'Paris', 1),
          ],
        ));

    // One group, expanded like any other — no special seeding in either
    // direction; the header stays a live per-group toggle.
    expect(find.text('Louvre'), findsOneWidget);
    await collapseCity(tester, 'Paris');
    expect(find.text('Louvre'), findsNothing);
    await toggleCity(tester, 'Paris');
    expect(find.text('Orsay'), findsOneWidget);
  });

  testWidgets('collapsed headers scroll as full-height rows (no squish)',
      (WidgetTester tester) async {
    // Eight collapsed groups in the default 600px viewport: scrolling pins
    // the chrome, which used to subtract its overlap from every zero-body
    // pinned group — headers squished to slivers, then vanished, leaving
    // phantom scroll extent. Groups now land expanded, so build the shape
    // by hand: collapse all eight on a tall surface (offscreen taps no-op),
    // then shrink back to the 600px viewport the regression lived in.
    final trip = Trip(
      id: 't1',
      title: 'Grand Tour',
      startDate: '2026-06-10',
      endDate: '2026-06-18',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        for (var k = 1; k <= 8; k++) _item(k, 'Place $k', 'Stop$k', k),
      ],
    );
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester, trip);

    for (var k = 1; k <= 8; k++) {
      await collapseCity(tester, 'Stop$k');
    }
    expect(find.textContaining('Place '), findsNothing);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpAndSettle();

    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    // The tail headers render at full row spacing, on screen — not
    // squished, not blank.
    final dy7 = tester.getTopLeft(find.text('Stop7')).dy;
    final dy8 = tester.getTopLeft(find.text('Stop8')).dy;
    expect(dy8 - dy7, greaterThan(40));
    expect(dy8, lessThan(600));
  });

  testWidgets(
      'a collapsed day header scrolls at full height inside an expanded group',
      (WidgetTester tester) async {
    // Same zero-body pinned hazard one level down: a collapsed day's header
    // used to vanish once the chrome plus the pinned city header exceeded
    // its height.
    final trip = Trip(
      id: 't1',
      title: 'Getaway',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        for (var d = 1; d <= 4; d++)
          for (var k = 0; k < 3; k++)
            _item((d - 1) * 3 + k, 'D$d stop $k', 'Paris', d),
      ],
    );
    await _pump(tester, trip);

    // The group lands expanded like any other; collapse every day — four
    // consecutive zero-body day sections, the same stacked shape as
    // collapsed cities.
    for (final label in const [
      'Wed, Jun 10',
      'Thu, Jun 11',
      'Fri, Jun 12',
      'Sat, Jun 13'
    ]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(find.text('D1 stop 0'), findsNothing);

    // Deep enough that the pinned chrome and city header have scrolled in —
    // the overlap that used to compress the zero-body day sections.
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    // Consecutive collapsed day headers keep their full row spacing.
    final dy2 = tester.getTopLeft(find.text('Thu, Jun 11')).dy;
    final dy3 = tester.getTopLeft(find.text('Fri, Jun 12')).dy;
    final dy4 = tester.getTopLeft(find.text('Sat, Jun 13')).dy;
    expect(dy3 - dy2, greaterThan(30));
    expect(dy4 - dy3, greaterThan(30));
  });

  testWidgets('collapse state survives a silent refresh',
      (WidgetTester tester) async {
    final service = await _pump(tester, twoCityTrip());

    await collapseCity(tester, 'Paris');
    expect(find.text('Louvre'), findsNothing);

    // Pull-to-refresh really refetches (the fake counts calls) without
    // resetting the user's collapse state — session state, and no seed
    // exists to re-fire and reopen anything.
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(service.calls, greaterThan(1));
    expect(find.text('Louvre'), findsNothing);
    expect(find.text('Colosseum'), findsOneWidget);
  });

  testWidgets(
      'cold start on a live trip lands on today with every group expanded',
      (WidgetTester tester) async {
    // Today is day 2 of a 3-day trip that started yesterday; day 1 is a
    // different city. Groups land expanded, so the one-shot auto-scroll has
    // nothing to open — it preselects today's leg on the map and scrolls
    // the list to today's header.
    final now = DateTime.now();
    final trip = Trip(
      id: 't1',
      title: 'Live Trip',
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

    expect(_position(tester).pixels, greaterThan(0));
    expect(find.text('Today stop 0'), findsOneWidget);
    expect(find.widgetWithText(StatusPill, 'Today'), findsOneWidget);

    // The Today jump chip re-expands after a manual collapse of the CITY
    // (the _scrollToDay un-collapse): collapse Rome in place — its pinned
    // header is under the chrome here — then park at the top.
    await collapseCity(tester, 'Rome');
    expect(find.text('Today stop 0'), findsNothing);
    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();

    // Paris landed expanded too (no collapse seed): its items are right
    // there at the top of the list.
    expect(find.text('Past stop 0'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, 'Today'));
    await tester.pumpAndSettle();
    expect(find.text('Today stop 0'), findsOneWidget);
    expect(_position(tester).pixels, greaterThan(0));
  });
}
