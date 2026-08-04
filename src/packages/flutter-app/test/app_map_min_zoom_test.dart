import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:travel_route_planner/widgets/app_map.dart';

/// World pixel width at [zoom] under Web Mercator (256px tiles).
double _worldWidth(double zoom) => 256 * math.pow(2, zoom).toDouble();

MapCamera _camera({
  required double zoom,
  LatLng center = const LatLng(0, 0),
  Size size = const Size(900, 240),
}) =>
    MapCamera(
      crs: const AppMapCrs(),
      center: center,
      zoom: zoom,
      rotation: 0,
      nonRotatedSize: size,
    );

void main() {
  group('appMapMinZoomFor', () {
    test('never drops below the legacy floor of 1', () {
      // At or below a 512px viewport, z1's 512px world already fills it.
      for (final w in [1.0, 360.0, 400.0, 512.0]) {
        expect(appMapMinZoomFor(w), 1, reason: 'width $w');
      }
    });

    test('guards return the legacy floor for degenerate widths', () {
      expect(appMapMinZoomFor(0), 1);
      expect(appMapMinZoomFor(-100), 1);
      expect(appMapMinZoomFor(double.infinity), 1);
      expect(appMapMinZoomFor(double.nan), 1);
    });

    test('world at the floor always fills the viewport width', () {
      for (final w in [513.0, 640.0, 868.0, 900.0, 1024.0, 1440.0, 2560.0]) {
        final world = _worldWidth(appMapMinZoomFor(w));
        expect(world, greaterThanOrEqualTo(w), reason: 'width $w');
        // ...but only barely: the epsilon must not over-zoom the fit.
        expect(world, lessThan(w * 1.02), reason: 'width $w');
      }
    });
  });

  group('AppMapCameraConstraint', () {
    const constraint = AppMapCameraConstraint();

    test('is identity on the pre-layout camera (impossible size)', () {
      final camera =
          _camera(zoom: 2).withNonRotatedSize(MapCamera.kImpossibleSize);
      expect(identical(constraint.constrain(camera), camera), isTrue);
    });

    test(
        'is identity (not null / frozen) when the world is narrower than '
        'the viewport', () {
      // z1 = 512px world inside a 900px viewport — below the minZoom floor,
      // reachable only transiently. ContainCamera-style math would bail with
      // null here, which freezes the map; we must hand the camera back.
      final camera = _camera(zoom: 1);
      expect(identical(constraint.constrain(camera), camera), isTrue);
    });

    test('clamps center latitude to ±85 like the old containCenter', () {
      final constrained =
          constraint.constrain(_camera(zoom: 5, center: const LatLng(89, 10)));
      expect(constrained.center.latitude, 85);
      expect(constrained.center.longitude, 10);
    });

    test('keeps the world edges outside the viewport at the zoom floor', () {
      final zoom = appMapMinZoomFor(900);
      final constrained = constraint
          .constrain(_camera(zoom: zoom, center: const LatLng(0, 157)));
      // Projection is linear in longitude, so the limit is exact: the center
      // may sit at most half a viewport short of either world edge.
      final maxLng = 180 * (1 - 900 / _worldWidth(zoom));
      expect(constrained.center.longitude, closeTo(maxLng, 1e-9));

      // And the visible edges confirm no background is exposed.
      expect(
        constrained.latLngToScreenOffset(const LatLng(0, -180)).dx,
        lessThanOrEqualTo(0.5),
      );
      expect(
        constrained.latLngToScreenOffset(const LatLng(0, 180)).dx,
        greaterThanOrEqualTo(899.5),
      );
    });

    test('allows wider centers once zoomed past the floor', () {
      final zoom = appMapMinZoomFor(900) + 1;
      final constrained = constraint
          .constrain(_camera(zoom: zoom, center: const LatLng(0, 157)));
      final maxLng = 180 * (1 - 900 / _worldWidth(zoom));
      expect(maxLng, greaterThan(45)); // sanity: room to roam at z+1
      expect(constrained.center.longitude, closeTo(maxLng, 1e-9));
    });

    test('is identity for an already-compliant camera', () {
      final zoom = appMapMinZoomFor(900) + 1;
      final camera = _camera(zoom: zoom, center: const LatLng(20, 30));
      expect(identical(constraint.constrain(camera), camera), isTrue);
    });
  });
}
