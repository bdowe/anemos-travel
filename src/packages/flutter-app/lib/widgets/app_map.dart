import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';

/// Space-dark canvas behind the tiles: unloaded/failed satellite tiles read as
/// "not lit yet" instead of a broken grey hole. Pass as
/// `MapOptions.backgroundColor` wherever [appMapTileLayers] is used.
const Color appMapBackground = Color(0xFF0A0F1A);

/// Web Mercator that draws exactly **one** world.
///
/// flutter_map's stock [Epsg3857] replicates longitude, so tiles, pins and
/// route lines repeat sideways whenever the world is narrower than the
/// viewport. Our maps are short, fixed-height bands (240px) that auto-fit a
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
/// planet. Callers pass whichever framing they have — a center+zoom or a
/// [CameraFit] — plus their interaction flags.
MapOptions appMapOptions({
  LatLng? initialCenter,
  double? initialZoom,
  CameraFit? initialCameraFit,
  required InteractionOptions interactionOptions,
}) {
  return MapOptions(
    crs: const AppMapCrs(),
    backgroundColor: appMapBackground,
    // Keeps the camera *center* on the world, so a pan can't drift off into
    // empty background. Deliberately not CameraConstraint.contain: that one
    // rejects any camera it cannot fit inside the bounds (returning null),
    // which would freeze a map taller than the world is wide.
    cameraConstraint: CameraConstraint.containCenter(
      bounds: LatLngBounds(const LatLng(-85, -180), const LatLng(85, 180)),
    ),
    // Without a floor, zooming out shrinks the single world to a postage
    // stamp and then past the smallest tile level into empty background.
    // z1 = a 512px world, which still fills our 240px map bands vertically
    // and is far below any real trip's auto-fit zoom (that would need ~130°
    // of latitude in one trip), so the fit is never clamped by this.
    minZoom: 1,
    initialCenter: initialCenter ?? const LatLng(0, 0),
    initialZoom: initialZoom ?? 13,
    initialCameraFit: initialCameraFit,
    interactionOptions: interactionOptions,
  );
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
