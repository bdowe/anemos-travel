import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/screens/trip_map_screen.dart';
import 'package:travel_route_planner/widgets/map_day_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Real (tight Paris-cluster) coordinates so the trip detail screen mounts a
/// live TripMap instead of skipping it.
ItineraryItem _item(int pos, String name, double lat, double lng, int day) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: 'Paris',
    );

void main() {
  final trip = Trip(
    id: 't1',
    title: 'Paris',
    status: 'planned',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    startDate: '2026-09-01',
    endDate: '2026-09-03',
    items: [
      _item(0, 'Louvre', 48.8606, 2.3376, 1),
      _item(1, 'Orsay', 48.8600, 2.3266, 1),
      _item(2, 'Pantheon', 48.8462, 2.3464, 2),
    ],
    accommodations: const [
      Accommodation(
        id: 'a1',
        name: 'Night One Hotel',
        latitude: 48.8630,
        longitude: 2.3364,
        checkIn: '2026-09-01',
        checkOut: '2026-09-02',
      ),
    ],
  );

  Future<void> pumpScreen(WidgetTester tester, {required Size surface}) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // Smallest realistic phone (iPhone SE class); the design floor.
  const phone = Size(375, 667);

  Finder inMap(Finder matching) =>
      find.descendant(of: find.byType(TripMap), matching: matching);

  testWidgets('phone: map is a static preview and scrolls away with the page',
      (WidgetTester tester) async {
    await pumpScreen(tester, surface: phone);

    // Static preview: no zoom/reset controls, but an expand affordance.
    expect(inMap(find.byIcon(Icons.add)), findsNothing);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);

    // A drag STARTING ON THE MAP must scroll the page (the old pinned map
    // panned instead) — and the unpinned map must leave the viewport.
    final mapTopBefore = tester.getTopLeft(find.byType(TripMap)).dy;
    await tester.drag(find.byType(TripMap), const Offset(0, -400),
        warnIfMissed: false);
    await tester.pump();
    final mapFinder = find.byType(TripMap);
    if (mapFinder.evaluate().isEmpty) {
      // Scrolled fully out and unmounted — exactly what we want.
    } else {
      expect(tester.getTopLeft(mapFinder).dy, lessThan(mapTopBefore));
    }
  });

  testWidgets(
      'phone: tapping the map opens the full-screen map; a day picked '
      'there survives closing', (WidgetTester tester) async {
    await pumpScreen(tester, surface: phone);

    await tester.tap(find.byType(TripMap), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsOneWidget);
    // Full interaction restored: zoom controls and day chips.
    expect(inMap(find.byIcon(Icons.add)), findsOneWidget);
    final chips = find.byType(MapDayChips);
    expect(chips, findsOneWidget);

    await tester.tap(find.descendant(of: chips, matching: find.text('Day 2')));
    await tester.pump();
    await tester.pump(); // post-frame camera re-fit

    // Day filter applies inside the full-screen map.
    final fullMap = tester.widget<TripMap>(find.byType(TripMap));
    expect(fullMap.items.map((i) => i.name), ['Pantheon']);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    // Back on the trip screen, the inline chips kept the selection.
    expect(find.byType(TripMapScreen), findsNothing);
    final inlineChips = tester.widget<MapDayChips>(find.byType(MapDayChips));
    expect(inlineChips.selected, 2);
    final inlineMap = tester.widget<TripMap>(find.byType(TripMap));
    expect(inlineMap.items.map((i) => i.name), ['Pantheon']);
  });

  testWidgets('wide: map keeps the pinned interactive treatment',
      (WidgetTester tester) async {
    await pumpScreen(tester, surface: const Size(1200, 800));

    // Interactive inline: zoom controls present, plus the fullscreen control
    // in the map's own strip (the full-screen map used to be unreachable at
    // wide widths).
    expect(inMap(find.byIcon(Icons.add)), findsOneWidget);
    expect(inMap(find.byIcon(Icons.fullscreen)), findsOneWidget);

    // Pinned: scrolling the page leaves the map in the viewport.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pump();
    expect(find.byType(TripMap), findsOneWidget);
  });

  testWidgets(
      'wide: the fullscreen control opens the full-screen map; a day picked '
      'there survives closing', (WidgetTester tester) async {
    await pumpScreen(tester, surface: const Size(1200, 800));

    await tester.tap(inMap(find.byIcon(Icons.fullscreen)));
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsOneWidget);

    final chips = find.byType(MapDayChips);
    await tester.tap(find.descendant(of: chips, matching: find.text('Day 2')));
    await tester.pump();
    await tester.pump(); // post-frame camera re-fit

    final fullMap = tester.widget<TripMap>(find.byType(TripMap));
    expect(fullMap.items.map((i) => i.name), ['Pantheon']);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    // Back on the trip screen, the inline chips kept the selection.
    expect(find.byType(TripMapScreen), findsNothing);
    final inlineChips = tester.widget<MapDayChips>(find.byType(MapDayChips));
    expect(inlineChips.selected, 2);
  });

  testWidgets(
      'escape key closes the full-screen map; a day picked '
      'there survives closing', (WidgetTester tester) async {
    await pumpScreen(tester, surface: phone);

    await tester.tap(find.byType(TripMap), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsOneWidget);

    final chips = find.byType(MapDayChips);
    await tester.tap(find.descendant(of: chips, matching: find.text('Day 2')));
    await tester.pump();
    await tester.pump(); // post-frame camera re-fit

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Same pop path as the close button: screen gone, selection kept.
    expect(find.byType(TripMapScreen), findsNothing);
    final inlineChips = tester.widget<MapDayChips>(find.byType(MapDayChips));
    expect(inlineChips.selected, 2);
  });

  testWidgets("escape closes the map from a pin-less day's empty state",
      (WidgetTester tester) async {
    // Wide surface: the phone-size inline preview behind the route has a
    // pre-existing EmptyState overflow on pin-less days that would fail this
    // test before Escape is ever pressed.
    await pumpScreen(tester, surface: const Size(1200, 800));

    await tester.tap(inMap(find.byIcon(Icons.fullscreen)));
    await tester.pumpAndSettle();

    // Day 3 has no pins: TripMap drops the FlutterMap (and its focused
    // node) for the empty state, so Escape must work from the bare route
    // scope — the case an in-screen shortcut wrapper would miss.
    final chips = find.byType(MapDayChips);
    await tester.tap(find.descendant(of: chips, matching: find.text('Day 3')));
    await tester.pumpAndSettle();
    expect(find.text('No places pinned on Day 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsNothing);
  });
}
