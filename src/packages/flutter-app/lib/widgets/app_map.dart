import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';

/// Space-dark canvas behind the tiles: unloaded/failed satellite tiles read as
/// "not lit yet" instead of a broken grey hole. Pass as
/// `MapOptions.backgroundColor` wherever [appMapTileLayers] is used.
const Color appMapBackground = Color(0xFF0A0F1A);

/// Nudges the computed zoom floor up so floating-point rounding can never
/// leave a sub-pixel sliver of background at the world's edges (the world
/// ends up ~0.7% wider than the viewport).
const double _minZoomEpsilon = 0.01;

/// Lowest zoom at which the single world (256·2^z px wide) still fills a
/// viewport of [viewportWidth] px horizontally; never below the legacy floor
/// of 1. Pass as `minZoom` to [appMapOptions] so neither an auto-fit nor a
/// user zoom-out can shrink the world narrower than the map box, which would
/// expose [appMapBackground] as bars down both sides.
double appMapMinZoomFor(double viewportWidth) {
  // At or below 512px (all phone bands) z1's 512px world already fills the
  // box — power-of-two exact, no epsilon needed — keeping the floor
  // identical to the pre-dynamic behavior there.
  if (!viewportWidth.isFinite || viewportWidth <= 512) return 1;
  return math.log(viewportWidth / 256) / math.ln2 + _minZoomEpsilon;
}

/// Web Mercator that draws exactly **one** world.
///
/// flutter_map's stock [Epsg3857] replicates longitude, so tiles, pins and
/// route lines repeat sideways whenever the world is narrower than the
/// viewport. Our maps are short, fixed-height bands that auto-fit a
/// trip's full extent: on a wide window a tall trip forces a zoom low enough
/// that two or three copies of the planet sit side by side — visually a bug.
/// Drawing a single world shows [appMapBackground] past the edges instead.
///
/// This wraps rather than extends [Epsg3857] because the two knobs that drive
/// repetition live in different places: `replicatesWorldLongitude` is a
/// virtual getter (markers, polylines, camera), while `wrapLng` is a
/// `@nonVirtual` field on [Crs] that the tile layer reads to pick a wrapping
/// [TileBounds]. Only a CRS constructed with `wrapLng: null` stops the tiles
/// repeating; all the projection math is delegated to a real [Epsg3857].
class AppMapCrs extends Crs {
  /// Create the app's single-world Web Mercator CRS.
  const AppMapCrs() : super(code: 'EPSG:3857', infinite: false);

  static const Epsg3857 _mercator = Epsg3857();

  @override
  Projection get projection => _mercator.projection;

  @override
  bool get replicatesWorldLongitude => false;

  @override
  (double, double) transform(double x, double y, double scale) =>
      _mercator.transform(x, y, scale);

  @override
  (double, double) untransform(double x, double y, double scale) =>
      _mercator.untransform(x, y, scale);

  @override
  (double, double) latLngToXY(LatLng latlng, double scale) =>
      _mercator.latLngToXY(latlng, scale);

  @override
  Offset latLngToOffset(LatLng latlng, double zoom) =>
      _mercator.latLngToOffset(latlng, zoom);

  @override
  LatLng offsetToLatLng(Offset point, double zoom) =>
      _mercator.offsetToLatLng(point, zoom);

  @override
  Rect? getProjectedBounds(double zoom) => _mercator.getProjectedBounds(zoom);
}

/// Shared [MapOptions] for every [FlutterMap] in the app: single-world
/// rendering, the space-dark backdrop, and a camera that can't wander off the
/// planet. Callers pass whichever framing they have — a center+zoom or an
/// [AppCameraFitBounds] — plus their interaction flags.
///
/// The fit parameter is deliberately the value-equal [AppCameraFitBounds],
/// not the raw [CameraFit]: a raw fit compares by identity, which silently
/// breaks the `MapOptions.==` short-circuit this helper exists to enable
/// (see [AppCameraFitBounds]).
MapOptions appMapOptions({
  LatLng? initialCenter,
  double? initialZoom,
  AppCameraFitBounds? initialCameraFit,
  double minZoom = 1,
  required InteractionOptions interactionOptions,
}) {
  return MapOptions(
    crs: const AppMapCrs(),
    backgroundColor: appMapBackground,
    // Keeps the world edges outside the viewport horizontally (no background
    // bars from a pan or an off-meridian fit) and the camera center on the
    // planet vertically. Deliberately not CameraConstraint.contain: that one
    // rejects any camera it cannot fit inside the bounds (returning null),
    // which would freeze a map taller than the world is wide.
    cameraConstraint: const AppMapCameraConstraint(),
    // Without a floor, zooming out shrinks the single world to a postage
    // stamp and then past the smallest tile level into empty background.
    // Callers with a known width pass [appMapMinZoomFor] so the world always
    // fills the viewport horizontally — the camera fit clamps up to it, which
    // trades vertical fit in our short map bands (an extreme-latitude trip
    // may need a pan to reach its outermost pins) for never showing bars.
    minZoom: minZoom,
    initialCenter: initialCenter ?? const LatLng(0, 0),
    initialZoom: initialZoom ?? 13,
    initialCameraFit: initialCameraFit,
    interactionOptions: interactionOptions,
  );
}

/// Camera constraint for the single-world [AppMapCrs]: contains the world
/// *edges* horizontally (a pan or off-center fit can never drag ±180° inside
/// the viewport and expose [appMapBackground] as side bars) while only
/// containing the camera *center* vertically at ±85° (edge-containing
/// latitude would freeze any map taller than the world, per the note on
/// [appMapOptions]).
///
/// Horizontal containment is only possible when the world is at least as
/// wide as the viewport — [appMapMinZoomFor] guarantees that; below the
/// floor (transient states only) the camera is returned unchanged rather
/// than `null`, which would freeze the map.
@immutable
class AppMapCameraConstraint extends CameraConstraint {
  /// Create the app's single-world camera constraint.
  const AppMapCameraConstraint();

  static const double _maxLatitude = 85;

  @override
  MapCamera constrain(MapCamera camera) {
    // The controller applies its options (and debug-asserts constraint
    // compliance) once before the first layout, while the camera still has
    // the sentinel "impossible" size — nothing sensible to contain yet.
    final size = camera.nonRotatedSize;
    if (size == MapCamera.kImpossibleSize ||
        !size.width.isFinite ||
        size.width <= 0) {
      return camera;
    }

    final zoom = camera.zoom;
    final center = LatLng(
      camera.center.latitude.clamp(-_maxLatitude, _maxLatitude),
      camera.center.longitude,
    );

    // Mirror ContainCamera's x-axis math against the whole world.
    final westPix = camera.projectAtZoom(const LatLng(0, -180), zoom);
    final eastPix = camera.projectAtZoom(const LatLng(0, 180), zoom);
    final halfWidth = camera.size.width / 2;
    final leftOkCenter = math.min(westPix.dx, eastPix.dx) + halfWidth;
    final rightOkCenter = math.max(westPix.dx, eastPix.dx) - halfWidth;

    // World narrower than the viewport: no horizontal containment exists
    // (transiently possible below the [appMapMinZoomFor] floor).
    if (leftOkCenter > rightOkCenter) {
      if (center == camera.center) return camera;
      return camera.withPosition(center: center);
    }

    final centerPix = camera.projectAtZoom(center, zoom);
    final newX = centerPix.dx.clamp(leftOkCenter, rightOkCenter);
    if (newX == centerPix.dx) {
      if (center == camera.center) return camera;
      return camera.withPosition(center: center);
    }
    return camera.withPosition(
      center: camera.unprojectAtZoom(Offset(newX, centerPix.dy), zoom),
    );
  }

  @override
  bool operator ==(Object other) => other is AppMapCameraConstraint;

  @override
  int get hashCode => (AppMapCameraConstraint).hashCode;
}

/// Value-equal [CameraFit.bounds].
///
/// flutter_map compares [MapOptions] by value, but a [CameraFit] only by
/// identity — so a fit constructed fresh each build makes `MapOptions.==`
/// fail and every rebuild re-runs the map controller's options setter: a new
/// controller state plus `notifyListeners` through the whole map subtree
/// (tile, polyline, marker and cluster layers all rebuild for nothing). The
/// initial fit itself is applied only once per [FlutterMap] state, so equal
/// inputs producing an equal fit changes no camera behavior.
///
/// Wraps rather than subclasses [FitBounds] — its constructor is private —
/// the same delegation pattern as [AppMapCrs] above. Equality is defined on
/// exactly the two fields our maps feed the wrapped fit: [bounds] and
/// [padding].
@immutable
class AppCameraFitBounds extends CameraFit {
  /// The bounds the fitted camera must contain, per [CameraFit.bounds].
  final LatLngBounds bounds;

  /// Pixel padding around the fitted bounds, per [CameraFit.bounds].
  final EdgeInsets padding;

  final CameraFit _inner;

  /// Create a value-equal bounds fit.
  AppCameraFitBounds({required this.bounds, this.padding = EdgeInsets.zero})
      : _inner = CameraFit.bounds(bounds: bounds, padding: padding);

  @override
  MapCamera fit(MapCamera camera) => _inner.fit(camera);

  @override
  bool operator ==(Object other) =>
      other is AppCameraFitBounds &&
      bounds == other.bounds &&
      padding == other.padding;

  @override
  int get hashCode => Object.hash(bounds, padding);
}

/// Shared basemap for every map in the app: Esri World Imagery satellite
/// tiles with a labels-only overlay designed for dark imagery, so maps get a
/// premium "satellite globe" look (à la Flighty) with readable place names.
///
/// Use [appMapTileLayers] as the first children of a [FlutterMap] and
/// [appMapAttribution] as the last child (attribution is required by both
/// Esri's and CARTO's tile usage terms).
List<Widget> appMapTileLayers(BuildContext context) {
  // panBuffer 0: two stacked layers double every tile request, and the default
  // 1-tile offscreen ring can exhaust the browser's request pool in bursts
  // (net::ERR_INSUFFICIENT_RESOURCES), leaving permanent grey holes. The evict
  // strategy re-fetches errored tiles when they scroll back into view instead
  // of keeping the hole.
  return [
    // Satellite base. Note the ArcGIS {z}/{y}/{x} path order.
    TileLayer(
      urlTemplate:
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName: 'com.travelrouteplanner.app',
      panBuffer: 0,
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
    ),
    // Place/street names with a light halo, made to sit over dark basemaps.
    TileLayer(
      urlTemplate:
          'https://basemaps.cartocdn.com/rastertiles/dark_only_labels/{z}/{x}/{y}{r}.png',
      userAgentPackageName: 'com.travelrouteplanner.app',
      retinaMode: RetinaMode.isHighDensity(context),
      panBuffer: 0,
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
    ),
  ];
}

/// Collapsed-to-an-icon attribution for the layers in [appMapTileLayers].
Widget appMapAttribution() {
  return RichAttributionWidget(
    alignment: AttributionAlignment.bottomLeft,
    showFlutterMapAttribution: false,
    openButton: (context, open) => IconButton(
      onPressed: open,
      tooltip: context.l10n.appMapCredits,
      icon: const Icon(Icons.info_outline, size: 16, color: Colors.white70),
    ),
    attributions: const [
      TextSourceAttribution(
        'Powered by Esri — Source: Esri, Maxar, Earthstar Geographics',
        prependCopyright: false,
      ),
      TextSourceAttribution('CARTO'),
      TextSourceAttribution('OpenStreetMap contributors'),
    ],
  );
}

/// A small circular control overlaid on the map (zoom in/out, reset, expand).
/// Dark and translucent so it reads as a frosted chip over satellite imagery.
///
/// The painted circle stays [_visualSize]; a transparent halo pads the hit
/// box to [_hitTarget] (the 44px mobile touch minimum — every placement of
/// these controls is touch-first).
class MapControlButton extends StatelessWidget {
  static const double _hitTarget = 44;
  static const double _visualSize = 36;

  final IconData icon;
  final String? tooltip;
  final VoidCallback onTap;

  const MapControlButton({
    super.key,
    required this.icon,
    this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: _hitTarget,
      height: _hitTarget,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(
            // Ink (not Container) so the tap ripple still paints over the
            // frosted chip instead of underneath it.
            child: Ink(
              width: _visualSize,
              height: _visualSize,
              decoration: ShapeDecoration(
                color: AppColors.mapScrim,
                shape: const CircleBorder(
                  side: BorderSide(color: Colors.white24),
                ),
              ),
              child: Icon(icon, size: 20, color: Colors.white),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
