import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/widgets/app_map.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

ItineraryItem _item(int pos, String name, double lat, double lng) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
    );

/// Hosts the map at a fixed size (FlutterMap needs bounded constraints).
Widget _host(Widget child) => _hostSized(child, const Size(400, 300));

/// [_host] at an arbitrary size, for tests that need the wide map bands
/// where the single world is narrower than the box at low zooms.
Widget _hostSized(Widget child, Size size) => MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    );

/// The live camera of the mounted FlutterMap, read from an element inside its
/// subtree (TileLayer is always present).
MapCamera _camera(WidgetTester tester) =>
    MapCamera.of(tester.element(find.byType(TileLayer).first));

void main() {
  // Tight cluster of Paris-area coordinates so every marker stays in the
  // viewport at the auto-fit zoom.
  final items = [
    _item(0, 'Louvre', 48.8606, 2.3376),
    _item(1, 'Café de Flore', 48.8540, 2.3326),
  ];

  testWidgets('builds without accommodations (default keeps old call sites)', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(TripMap(items: items)));
    await tester.pump();

    expect(find.byType(TripMap), findsOneWidget);
    expect(find.byIcon(Icons.hotel), findsNothing);
  });

  testWidgets('renders one stay marker per stay with coordinates', (
    WidgetTester tester,
  ) async {
    const stays = [
      Accommodation(
        id: 'a1',
        name: 'Hôtel du Louvre',
        latitude: 48.8630,
        longitude: 2.3364,
        checkIn: '2026-06-10',
        checkOut: '2026-06-12',
      ),
      Accommodation(
        id: 'a2',
        name: 'Left Bank Flat',
        latitude: 48.8520,
        longitude: 2.3330,
      ),
      // No coordinates: must be skipped, not plotted at (0, 0).
      Accommodation(id: 'a3', name: 'Ungeocoded Stay'),
    ];

    await tester.pumpWidget(
      _host(TripMap(items: items, accommodations: stays)),
    );
    await tester.pump();

    expect(find.byIcon(Icons.hotel), findsNWidgets(2));

    // Tapping a stay is a tooltip affair (name + dates), not selection sync.
    final tooltips = tester
        .widgetList<Tooltip>(
          find.ancestor(
            of: find.byIcon(Icons.hotel),
            matching: find.byType(Tooltip),
          ),
        )
        .map((t) => t.message)
        .toList();
    expect(tooltips, contains('Hôtel du Louvre\nJun 10 – Jun 12'));
    expect(tooltips, contains('Left Bank Flat')); // no dates -> name only
  });

  testWidgets('custom emptyLabel renders when nothing is mappable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(const TripMap(items: [], emptyLabel: 'No mapped places on Day 3')),
    );
    await tester.pump();

    expect(find.text('No mapped places on Day 3'), findsOneWidget);
    expect(find.text('No mapped places'), findsNothing);
  });

  testWidgets('default emptyLabel keeps the existing message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const TripMap(items: [])));
    await tester.pump();

    expect(find.text('No mapped places'), findsOneWidget);
  });

  testWidgets('empty state renders the optional message and CTA', (
    WidgetTester tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        TripMap(
          items: const [],
          emptyMessage: 'Add a place to see it on the map.',
          emptyAction: FilledButton(
            onPressed: () => tapped = true,
            child: const Text('Add place'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Add a place to see it on the map.'), findsOneWidget);
    await tester.tap(find.text('Add place'));
    expect(tapped, isTrue);
  });

  testWidgets('changing fitSignature re-fits without crashing (smoke)', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(TripMap(items: items, fitSignature: 'all')));
    await tester.pump();

    // Filtered down to one item under a new signature: the post-frame re-fit
    // must run against the live controller without throwing.
    await tester.pumpWidget(
      _host(TripMap(items: [items.first], fitSignature: 'day-1')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(TripMap), findsOneWidget);

    // Signature change while nothing is mappable (empty state, no live map)
    // must be a no-op, not a crash.
    await tester.pumpWidget(
      _host(const TripMap(items: [], fitSignature: 'day-2')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('No mapped places'), findsOneWidget);
  });

  testWidgets(
    'adding a far-away item with unchanged fitSignature re-fits the camera '
    'to contain all points',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(TripMap(items: items, fitSignature: 'all')),
      );
      await tester.pump();

      // Marseille: well outside the Paris-fit viewport, so the final assertions
      // below are exactly what the pre-fix code violates.
      const far = LatLng(43.2965, 5.3698);
      expect(_camera(tester).visibleBounds.contains(far), isFalse);

      await tester.pumpWidget(
        _host(
          TripMap(
            items: [
              ...items,
              _item(2, 'Vieux-Port', far.latitude, far.longitude),
            ],
            fitSignature: 'all', // unchanged — the bug condition
          ),
        ),
      );
      await tester.pump(); // frame rendering the new pin schedules the re-fit
      await tester.pump(); // post-frame callback has run; camera updated

      final bounds = _camera(tester).visibleBounds;
      expect(bounds.contains(far), isTrue);
      for (final it in items) {
        expect(bounds.contains(LatLng(it.latitude, it.longitude)), isTrue);
      }
    },
  );

  testWidgets(
    'content change while a pin is selected does not yank the camera',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(TripMap(items: items, selectedPosition: 0, fitSignature: 'all')),
      );
      await tester.pump();

      // Initial mount centers on the selected item at zoom 15.
      expect(_camera(tester).zoom, 15);

      const far = LatLng(43.2965, 5.3698);
      await tester.pumpWidget(
        _host(
          TripMap(
            items: [
              ...items,
              _item(2, 'Vieux-Port', far.latitude, far.longitude),
            ],
            selectedPosition: 0,
            fitSignature: 'all',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final camera = _camera(tester);
      expect(camera.zoom, 15);
      expect(camera.center.latitude, closeTo(48.8606, 1e-4)); // still on Louvre
      expect(camera.visibleBounds.contains(far), isFalse);
    },
  );

  testWidgets('empty state to mapped content frames all points', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const TripMap(items: [])));
    await tester.pump();
    expect(find.text('No mapped places'), findsOneWidget);

    await tester.pumpWidget(_host(TripMap(items: items)));
    await tester.pump();
    await tester.pump();

    final bounds = _camera(tester).visibleBounds;
    for (final it in items) {
      expect(bounds.contains(LatLng(it.latitude, it.longitude)), isTrue);
    }
  });

  testWidgets('reordering items does not move the camera', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(TripMap(items: items)));
    await tester.pump();

    final before = _camera(tester);
    await tester.pumpWidget(_host(TripMap(items: items.reversed.toList())));
    await tester.pump();
    await tester.pump();

    final after = _camera(tester);
    expect(after.zoom, before.zoom);
    expect(after.center, before.center);
  });

  testWidgets('segment label shows when the leg is long enough on screen', (
    WidgetTester tester,
  ) async {
    // The Paris pair alone fits at a high zoom, so the ~0.8km leg spans far
    // more than the visibility threshold.
    await tester.pumpWidget(
      _host(TripMap(items: items, segmentLabels: const {0: '12 min'})),
    );
    await tester.pump();

    expect(find.text('12 min'), findsOneWidget);
  });

  testWidgets('segment label hides when the leg converges at fit zoom', (
    WidgetTester tester,
  ) async {
    // Adding Marseille zooms the fit out to country scale, where the Paris
    // leg collapses to a few pixels — the pill would just sit behind the
    // numbered pins, so it must not render.
    await tester.pumpWidget(
      _host(
        TripMap(
          items: [...items, _item(2, 'Vieux-Port', 43.2965, 5.3698)],
          segmentLabels: const {0: '12 min'},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('12 min'), findsNothing);
    expect(find.byType(TripMap), findsOneWidget);
  });

  testWidgets('camera change re-evaluates segment label visibility', (
    WidgetTester tester,
  ) async {
    final threeItems = [...items, _item(2, 'Vieux-Port', 43.2965, 5.3698)];
    await tester.pumpWidget(
      _host(TripMap(items: threeItems, segmentLabels: const {0: '12 min'})),
    );
    await tester.pump();
    expect(find.text('12 min'), findsNothing);

    // Selecting a pin moves the camera to zoom 15, where the Paris leg is
    // hundreds of px long — the label must (re)appear without a rebuild of
    // the segment data.
    await tester.pumpWidget(
      _host(
        TripMap(
          items: threeItems,
          segmentLabels: const {0: '12 min'},
          selectedPosition: 0,
        ),
      ),
    );
    await tester.pump(); // frame scheduling the post-frame camera move
    await tester.pump(); // camera moved; label layer rebuilt

    expect(find.text('12 min'), findsOneWidget);
  });

  testWidgets('topOverlayInset keeps fitted markers below the overlay band', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(TripMap(items: items, topOverlayInset: 48)));
    await tester.pump();

    // Topmost point (Louvre) must clear the 48px chip band at the fit.
    final dy = _camera(
      tester,
    ).latLngToScreenOffset(const LatLng(48.8606, 2.3376)).dy;
    expect(dy, greaterThanOrEqualTo(48));
  });

  testWidgets('pins number 1..N over the shown items, not trip-wide position', (
    WidgetTester tester,
  ) async {
    // A day-filtered (or partially geocoded) view hands the map items whose
    // positions start mid-trip; the labels must still read 1, 2 in route
    // order rather than exposing positions 5, 6 as "6", "7".
    await tester.pumpWidget(
      _host(
        TripMap(
          items: [
            _item(5, 'Louvre', 48.8606, 2.3376),
            _item(6, 'Café de Flore', 48.8540, 2.3326),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('6'), findsNothing);
    expect(find.text('7'), findsNothing);
  });

  testWidgets('interactive: false hides the zoom/reset controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(TripMap(items: items, interactive: false)));
    await tester.pump();

    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byIcon(Icons.remove), findsNothing);
    expect(find.byIcon(Icons.zoom_in_map), findsNothing);
  });

  testWidgets('default (interactive) keeps the zoom/reset controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(TripMap(items: items)));
    await tester.pump();

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.zoom_in_map), findsOneWidget);
  });

  testWidgets('pin dot stays anchored on its coordinate inside the 44px box', (
    WidgetTester tester,
  ) async {
    // The widened tap halo must not drift the painted dot: the marker box is
    // center-anchored, so the dot's on-screen center has to sit exactly on
    // the projected coordinate.
    await tester.pumpWidget(_host(TripMap(items: [items.first])));
    await tester.pump();

    final mapTopLeft = tester.getTopLeft(find.byType(FlutterMap));
    final projected = _camera(
      tester,
    ).latLngToScreenOffset(const LatLng(48.8606, 2.3376));
    final pinCenter = tester.getCenter(find.text('1'));
    expect((pinCenter - (mapTopLeft + projected)).distance, lessThan(1.0));
  });

  testWidgets('taps in the widened pin halo still select the pin', (
    WidgetTester tester,
  ) async {
    int? tappedPos;
    await tester.pumpWidget(
      _host(TripMap(items: [items.first], onPinTap: (p) => tappedPos = p)),
    );
    await tester.pump();

    // 18px below the dot center: outside the 24px dot, inside the 44px box.
    await tester.tapAt(tester.getCenter(find.text('1')) + const Offset(0, 18));
    expect(tappedPos, 0);
  });

  testWidgets('stay pin tooltip triggers from the widened halo', (
    WidgetTester tester,
  ) async {
    const stays = [
      Accommodation(
        id: 'a1',
        name: 'Hôtel du Louvre',
        latitude: 48.8630,
        longitude: 2.3364,
      ),
    ];
    await tester.pumpWidget(
      _host(const TripMap(items: [], accommodations: stays)),
    );
    await tester.pump();

    await tester.tapAt(
      tester.getCenter(find.byIcon(Icons.hotel)) + const Offset(0, 18),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // The tooltip overlay carries the message (name only — no dates given).
    expect(find.text('Hôtel du Louvre'), findsOneWidget);

    // Let the tap-triggered tooltip's show timer elapse and fade out so the
    // test ends without pending timers.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('map control buttons meet the 44px touch target', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(TripMap(items: items)));
    await tester.pump();

    final buttons = find.byType(MapControlButton);
    expect(buttons, findsNWidgets(3)); // zoom in / zoom out / reset
    for (var i = 0; i < 3; i++) {
      final size = tester.getSize(buttons.at(i));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
  });

  testWidgets('stays alone (no mapped items) still render a map', (
    WidgetTester tester,
  ) async {
    const stays = [
      Accommodation(
        id: 'a1',
        name: 'Hôtel du Louvre',
        latitude: 48.8630,
        longitude: 2.3364,
      ),
    ];

    await tester.pumpWidget(
      _host(const TripMap(items: [], accommodations: stays)),
    );
    await tester.pump();

    expect(find.text('No mapped places'), findsNothing);
    expect(find.byIcon(Icons.hotel), findsOneWidget);
  });

  group('single world fills a wide map band (no background side bars)', () {
    // Tokyo + Auckland: the auto-fit for this pair in a 900×240 band is
    // height-limited to a zoom *below* the width floor, and its bounds center
    // (~157°E) sits close enough to the antimeridian that even a
    // floor-clamped camera would show background on the right without the
    // longitude-containing constraint. Exercises both halves of the fix.
    final wideItems = [
      _item(0, 'Tokyo Tower', 35.6586, 139.7454),
      _item(1, 'Sky Tower', -36.8485, 174.7622),
    ];
    const band = Size(900, 240);

    /// No pixel of background may show beside the world: the west edge must
    /// project at/left of x=0 and the east edge at/right of x=band.width.
    void expectNoSideBars(WidgetTester tester) {
      final camera = _camera(tester);
      expect(
        camera.latLngToScreenOffset(const LatLng(0, -180)).dx,
        lessThanOrEqualTo(0.5),
      );
      expect(
        camera.latLngToScreenOffset(const LatLng(0, 180)).dx,
        greaterThanOrEqualTo(band.width - 0.5),
      );
    }

    Future<void> pumpWideTrip(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _hostSized(TripMap(items: wideItems), band),
      );
      await tester.pump();
    }

    testWidgets('auto-fit clamps to the width-aware zoom floor', (
      WidgetTester tester,
    ) async {
      await pumpWideTrip(tester);

      final camera = _camera(tester);
      expect(camera.minZoom, appMapMinZoomFor(band.width));
      expect(camera.zoom, greaterThanOrEqualTo(camera.minZoom!));
      expectNoSideBars(tester);
    });

    testWidgets('zooming out cannot shrink the world below the box width', (
      WidgetTester tester,
    ) async {
      await pumpWideTrip(tester);

      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();

      expect(
        _camera(tester).zoom,
        greaterThanOrEqualTo(appMapMinZoomFor(band.width)),
      );
      expectNoSideBars(tester);
    });

    testWidgets('reset re-fits without reintroducing bars', (
      WidgetTester tester,
    ) async {
      await pumpWideTrip(tester);

      await tester.tap(find.byIcon(Icons.zoom_in_map));
      await tester.pump();

      final camera = _camera(tester);
      expect(camera.zoom, greaterThanOrEqualTo(appMapMinZoomFor(band.width)));
      expectNoSideBars(tester);
    });
  });
}
