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
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Real coordinates so the trip detail screen mounts a live TripMap instead
/// of skipping it.
ItineraryItem _item(
  int pos,
  String name,
  String city,
  double lat,
  double lng,
  int day,
) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: city,
    );

void main() {
  // Paris (geocoded) → Rome (geocoded) → Berlin (UNgeocoded: the pin-less
  // leg the empty-state cases select). Multi-city so the leg strip renders.
  final trip = Trip(
    id: 't1',
    title: 'Paris & Rome',
    status: 'planned',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    startDate: '2026-09-01',
    endDate: '2026-09-03',
    items: [
      _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
      _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 1),
      _item(2, 'Colosseum', 'Rome', 41.8902, 12.4922, 2),
      _item(3, 'Berlin Walk', 'Berlin', 0, 0, 3),
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

  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(MapLegChips),
      matching: find.text(label),
    ));
    // Settles the camera re-fit and any focus-driven page scroll behind a
    // full-screen map.
    await tester.pumpAndSettle();
  }

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
      'phone: tapping the map opens the full-screen map; a leg picked '
      'there survives closing', (WidgetTester tester) async {
    await pumpScreen(tester, surface: phone);

    await tester.tap(find.byType(TripMap), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsOneWidget);
    // Full interaction restored: zoom controls and leg chips.
    expect(inMap(find.byIcon(Icons.add)), findsOneWidget);
    expect(find.byType(MapLegChips), findsOneWidget);

    await tapChip(tester, 'Rome');

    // Leg focus applies inside the full-screen map.
    final fullMap = tester.widget<TripMap>(find.byType(TripMap));
    expect(fullMap.items.map((i) => i.name), ['Colosseum']);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    // Back on the trip screen, the inline chips kept the focus.
    expect(find.byType(TripMapScreen), findsNothing);
    final inlineChips = tester.widget<MapLegChips>(find.byType(MapLegChips));
    expect(inlineChips.selected, 'Rome');
    final inlineMap = tester.widget<TripMap>(find.byType(TripMap));
    expect(inlineMap.items.map((i) => i.name), ['Colosseum']);
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
      'wide: the fullscreen control opens the full-screen map; a leg picked '
      'there survives closing', (WidgetTester tester) async {
    await pumpScreen(tester, surface: const Size(1200, 800));

    await tester.tap(inMap(find.byIcon(Icons.fullscreen)));
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsOneWidget);

    await tapChip(tester, 'Rome');

    final fullMap = tester.widget<TripMap>(find.byType(TripMap));
    expect(fullMap.items.map((i) => i.name), ['Colosseum']);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    // Back on the trip screen, the inline chips kept the focus.
    expect(find.byType(TripMapScreen), findsNothing);
    final inlineChips = tester.widget<MapLegChips>(find.byType(MapLegChips));
    expect(inlineChips.selected, 'Rome');
  });

  testWidgets(
      'phone: a pin-less leg keeps the inline preview inside its card '
      '(no hint, no overflow)', (WidgetTester tester) async {
    await pumpScreen(tester, surface: phone);

    await tapChip(tester, 'Berlin');

    // The preview shows only the label: the add-place hint invites an action
    // the pointer-absorbing preview can't take, and it's what overflowed the
    // 180px card. Widget tests rethrow RenderFlex overflows at test end —
    // settling cleanly here IS the no-overflow assertion.
    expect(find.text('No places pinned in Berlin'), findsOneWidget);
    expect(find.text('Add a place to see it on the map.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'escape key closes the full-screen map; a leg picked '
      'there survives closing', (WidgetTester tester) async {
    await pumpScreen(tester, surface: phone);

    await tester.tap(find.byType(TripMap), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsOneWidget);

    await tapChip(tester, 'Rome');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Same pop path as the close button: screen gone, focus kept.
    expect(find.byType(TripMapScreen), findsNothing);
    final inlineChips = tester.widget<MapLegChips>(find.byType(MapLegChips));
    expect(inlineChips.selected, 'Rome');
  });

  testWidgets("escape closes the map from a pin-less leg's empty state",
      (WidgetTester tester) async {
    await pumpScreen(tester, surface: phone);

    await tester.tap(find.byType(TripMap), warnIfMissed: false);
    await tester.pumpAndSettle();

    // Berlin has no pins: TripMap drops the FlutterMap (and its focused
    // node) for the empty state, so Escape must work from the bare route
    // scope — the case an in-screen shortcut wrapper would miss.
    await tapChip(tester, 'Berlin');
    expect(find.text('No places pinned in Berlin'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(TripMapScreen), findsNothing);
  });
}
