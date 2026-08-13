import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/hover_reveal.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';

import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

/// Trip-detail scroll-perf structure (the progressive-slowdown bug, 2026-08):
/// continuous scrolling got slower the longer it ran because (a) every row
/// crossing under a parked cursor started a 120ms AnimatedOpacity fade — a
/// rolling set of saveLayers per frame on CanvasKit — and (b) the pinned
/// chrome (map band, tab row, city/day headers) had no RepaintBoundary, so
/// its picture was re-recorded every scroll frame. These tests pin the two
/// structural fixes:
///   * no AnimatedOpacity anywhere on the screen — hover reveal is instant;
///   * the map card, pinned-header chrome, and city/day headers sit behind
///     RepaintBoundaries (the card's boundary lives INSIDE _mapCard, so both
///     the pinned wide band and the scroll-away phone card get it).
void main() {
  ItineraryItem item(int pos, String name, String city, double lat, double lng,
          int day) =>
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

  Trip threeCityTrip() => Trip(
        id: 't1',
        title: 'Grand tour',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        startDate: '2026-09-01',
        endDate: '2026-09-05',
        items: [
          item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
          item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
          for (var k = 0; k < 8; k++)
            item(2 + k, 'Roman Forum $k', 'Rome', 41.89 + k * 0.001, 12.49, 3),
          item(10, 'Brandenburg Gate', 'Berlin', 52.5163, 13.3777, 4),
        ],
      );

  Future<void> pump(WidgetTester tester, Trip trip) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();
  }

  void useSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// True when [finder]'s single match sits DIRECTLY inside a
  /// RepaintBoundary — the wrap shape this lane added (boundary → child by
  /// instance). Direct parenthood distinguishes our boundaries from any the
  /// framework happens to place higher up the tree.
  bool directlyBoundaried(WidgetTester tester, Finder finder) {
    Widget? parent;
    tester.element(finder).visitAncestorElements((e) {
      parent = e.widget;
      return false;
    });
    return parent is RepaintBoundary;
  }

  testWidgets(
      'wide layout: map card + pinned chrome + city/day headers are '
      'repaint-isolated and nothing on the screen fades', (tester) async {
    useSurface(tester, const Size(1200, 2200));
    await pump(tester, threeCityTrip());

    // The map card's boundary must be an ancestor of the chip strip (the
    // strip sits outside flutter_map's own internal boundary, so any
    // boundary above it inside the scroll view is ours).
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.ancestor(
          of: find.byType(MapLegChips),
          matching: find.byType(RepaintBoundary),
        ),
      ),
      findsWidgets,
      reason: 'the pinned map card must repaint in its own layer',
    );

    // City headers (collapsed at boot) are individually boundaried.
    expect(
      directlyBoundaried(
          tester,
          find
              .ancestor(
                  of: cityHeaderLabel('Paris'),
                  matching: find.byType(HoverReveal))
              .first),
      isTrue,
      reason: 'city headers must repaint in their own layer',
    );

    // Expanding a city mounts its pinned day headers — those are
    // boundaried too (city header + ≥1 day header ⇒ ≥2 direct wraps; item
    // tiles rely on the reorderable list's automatic row boundaries and are
    // deliberately NOT double-wrapped).
    await expandCity(tester, 'Paris');
    final directWraps = find
        .byType(HoverReveal)
        .evaluate()
        .where((e) => e.widget is HoverReveal)
        .where((e) {
      Widget? parent;
      e.visitAncestorElements((a) {
        parent = a.widget;
        return false;
      });
      return parent is RepaintBoundary;
    }).length;
    expect(directWraps, greaterThanOrEqualTo(2),
        reason: 'city and day headers must both carry direct boundaries');

    // The regression guard for the fade itself. Scoped to HoverReveal
    // subtrees: flutter_map legitimately keeps a couple of idle
    // AnimatedOpacity widgets (attribution chrome) that never animate on
    // scroll — the bug was fades on the hover-revealed row controls.
    expect(
        find.descendant(
            of: find.byType(HoverReveal),
            matching: find.byType(AnimatedOpacity)),
        findsNothing,
        reason: 'hover reveal must be an instant 0/1 swap — a fade brings '
            'back the rolling saveLayer cost that caused the scroll slowdown');
  });

  testWidgets('phone layout: the scroll-away map card is boundaried too',
      (tester) async {
    useSurface(tester, const Size(500, 900));
    await pump(tester, threeCityTrip());

    // Same assertion as the wide layout: proves the boundary lives inside
    // _mapCard rather than only in the pinned-header delegate.
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.ancestor(
          of: find.byType(MapLegChips),
          matching: find.byType(RepaintBoundary),
        ),
      ),
      findsWidgets,
    );
    expect(
        find.descendant(
            of: find.byType(HoverReveal),
            matching: find.byType(AnimatedOpacity)),
        findsNothing);
  });

  testWidgets('hover still reveals row controls with a mouse connected',
      (tester) async {
    useSurface(tester, const Size(1200, 2200));
    await pump(tester, threeCityTrip());
    await expandCity(tester, 'Paris');

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    Opacity tileControls() => tester.widget<Opacity>(find
        .descendant(
          of: find.ancestor(
              of: find.text('Louvre'), matching: find.byType(HoverReveal)),
          matching: find.byType(Opacity),
        )
        .first);

    // Pointer parked away from the tile: controls hidden, exactly 0.
    expect(tileControls().opacity, 0.0);

    // Hover the tile: controls appear after a single frame, exactly 1.
    await gesture.moveTo(tester.getCenter(find.text('Louvre')));
    await tester.pump();
    expect(tileControls().opacity, 1.0);
  });
}

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}
