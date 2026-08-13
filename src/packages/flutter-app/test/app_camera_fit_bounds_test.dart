import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/widgets/app_map.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

// flutter_map's MapOptions.== includes initialCameraFit, but CameraFit has no
// value equality — so a fit constructed fresh each build made every TripMap
// rebuild fail the equality check and re-run the controller's options setter
// (new controller state + notifyListeners → tile/polyline/marker/cluster
// layers all rebuilt for nothing). AppCameraFitBounds restores the
// short-circuit by defining == on exactly (bounds, padding). These tests pin
// the equality contract, fit() delegation parity, and the short-circuit
// itself: an identical parent re-pump must leave the controller holding the
// IDENTICAL MapOptions instance.

LatLngBounds _parisRome() => LatLngBounds.fromPoints(const [
      LatLng(48.8606, 2.3376),
      LatLng(41.8902, 12.4922),
    ]);

MapCamera _camera({
  required double zoom,
  LatLng center = const LatLng(45, 7),
  Size size = const Size(900, 240),
}) =>
    MapCamera(
      crs: const AppMapCrs(),
      center: center,
      zoom: zoom,
      rotation: 0,
      nonRotatedSize: size,
    );

ItineraryItem _item(int pos, String name, double lat, double lng) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
    );

// Far apart (Paris / Rome) so TripMap takes the bounds-fit options branch,
// never the single-point center+zoom branch.
final _itemsA = [
  _item(0, 'Louvre', 48.8606, 2.3376),
  _item(1, 'Colosseum', 41.8902, 12.4922),
];

Widget _app(List<ItineraryItem> items) => MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
      home: Scaffold(
        body: TripMap(
          items: items,
          onPinTap: (_) {},
        ),
      ),
    );

MapOptions _liveOptions(WidgetTester tester) =>
    MapOptions.of(tester.element(find.byType(TileLayer).first));

MapCamera _liveCamera(WidgetTester tester) =>
    MapCamera.of(tester.element(find.byType(TileLayer).first));

void main() {
  group('AppCameraFitBounds equality', () {
    test('equal-but-not-identical inputs compare equal', () {
      final a = AppCameraFitBounds(
        bounds: _parisRome(),
        padding: const EdgeInsets.all(24),
      );
      final b = AppCameraFitBounds(
        bounds: _parisRome(),
        padding: const EdgeInsets.all(24),
      );
      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('differing bounds or padding compare unequal', () {
      final base = AppCameraFitBounds(
        bounds: _parisRome(),
        padding: const EdgeInsets.all(24),
      );
      final otherBounds = AppCameraFitBounds(
        bounds: LatLngBounds.fromPoints(const [
          LatLng(48.8606, 2.3376),
          LatLng(41.8986, 12.4769),
        ]),
        padding: const EdgeInsets.all(24),
      );
      final otherPadding = AppCameraFitBounds(
        bounds: _parisRome(),
        padding: const EdgeInsets.all(32),
      );
      expect(base == otherBounds, isFalse);
      expect(base == otherPadding, isFalse);
    });

    test('a raw CameraFit.bounds is never equal (guards the type boundary)',
        () {
      final wrapped = AppCameraFitBounds(bounds: _parisRome());
      final raw = CameraFit.bounds(bounds: _parisRome());
      expect(wrapped == raw, isFalse);
    });
  });

  group('AppCameraFitBounds.fit', () {
    test('delegates to CameraFit.bounds — identical resulting camera', () {
      const padding = EdgeInsets.all(24);
      final camera = _camera(zoom: 5);
      final ours =
          AppCameraFitBounds(bounds: _parisRome(), padding: padding)
              .fit(camera);
      final reference =
          CameraFit.bounds(bounds: _parisRome(), padding: padding).fit(camera);
      expect(ours.center, reference.center);
      expect(ours.zoom, reference.zoom);
    });
  });

  group('options-setter short-circuit', () {
    testWidgets(
        'an identical parent re-pump leaves the controller holding the '
        'identical MapOptions instance', (tester) async {
      await tester.pumpWidget(_app(_itemsA));
      await tester.pump();
      final before = _liveOptions(tester);

      // Same items list, fresh TripMap widget — before the fix this built an
      // ==-unequal MapOptions (fresh identity-compared CameraFit) and the
      // controller adopted it; now didUpdateWidget must short-circuit.
      await tester.pumpWidget(_app(_itemsA));
      await tester.pump();
      expect(identical(_liveOptions(tester), before), isTrue);
    });

    testWidgets('a real content change still propagates new options',
        (tester) async {
      await tester.pumpWidget(_app(_itemsA));
      await tester.pump();
      final before = _liveOptions(tester);

      // Athens sits OUTSIDE the Paris–Rome bounding box, so the fit bounds
      // genuinely change. (An added pin inside the box keeps the bounds —
      // and, by design, the options — equal.)
      final itemsB = List.of(_itemsA)
        ..add(_item(2, 'Acropolis', 37.9715, 23.7267));
      await tester.pumpWidget(_app(itemsB));
      await tester.pump();
      expect(identical(_liveOptions(tester), before), isFalse);
    });

    testWidgets('rebuild after a user zoom does not move the camera',
        (tester) async {
      await tester.pumpWidget(_app(_itemsA));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      final zoomed = _liveCamera(tester);

      await tester.pumpWidget(_app(_itemsA));
      await tester.pump();
      final after = _liveCamera(tester);
      expect(after.zoom, zoomed.zoom);
      expect(after.center, zoomed.center);
    });
  });
}
