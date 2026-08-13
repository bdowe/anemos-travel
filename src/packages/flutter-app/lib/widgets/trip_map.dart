import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../theme/app_colors.dart';
import '../utils/trip_format.dart';
import 'app_map.dart';
import 'empty_state.dart';

/// Tap box (px) for interactive map pins. The painted dot stays small; the
/// surrounding transparent halo brings the target up to the mobile touch
/// minimum. Markers anchor by their box center (flutter_map's default
/// alignment), so the enlargement must stay symmetric with the visual
/// centered inside — anything else drifts pins off their coordinates on all
/// three map surfaces.
const double _pinHitBox = 44;

/// Clearance (px) for the day-chip band's visible pills when the empty state
/// is centered under it: 8px overlay offset + the ~32px pill + breathing
/// room. See the empty-state branch in [_TripMapState.build] for why this is
/// less than [TripMap.topOverlayInset]'s usual value.
const double _emptyStateTopInset = 44;

/// Home-airport overlay for the full-screen trip map: the home point plus
/// which travel legs to draw. A null endpoint hides that leg (e.g. a mid-trip
/// day-chip selection); with both endpoints null callers should pass
/// `home: null` instead so no orphan pin renders.
///
/// Limitation: a leg spanning more than 180° of longitude is dropped — the
/// map is a single non-wrapping world ([AppMapCrs]), so such a leg would draw
/// the long way around. When every leg drops, the whole overlay (pin and
/// camera-fit inclusion) is suppressed.
class TripMapHome {
  /// The home airport's coordinates.
  final LatLng point;

  /// First-city coordinate; non-null draws the outbound leg home → city.
  final LatLng? outboundTo;

  /// Last-city coordinate; non-null draws the return leg city → home.
  final LatLng? returnFrom;

  /// Bare IATA code (e.g. "EWR") for the pin's tooltip.
  final String label;

  const TripMapHome({
    required this.point,
    required this.label,
    this.outboundTo,
    this.returnFrom,
  });
}

/// A destination (city leg) pin for the trip-overview map. With at least two
/// of these, [TripMap] renders one numbered pin per entry — 1..N in list
/// (visit) order — instead of per-item pins, and walks the route line through
/// their coordinates. Callers derive the list from the FULL itinerary (never
/// a day/category-filtered view, which would shift the numbering) and pass
/// null on day views to restore per-item stop pins.
class TripMapDestination {
  /// Display label for the tooltip, already localized by the caller.
  final String label;

  /// The destination's representative coordinate.
  final LatLng point;

  /// Pre-formatted date range for the tooltip; null shows the label alone.
  final String? dates;

  const TripMapDestination({
    required this.label,
    required this.point,
    this.dates,
  });
}

/// Plots a trip's itinerary on a satellite basemap: a numbered, category-tinted
/// pin per place, a route line connecting them in itinerary order, auto-fit to
/// the trip's extent. Tapping a pin calls [onPinTap] with that item's position.
/// When [selectedPosition] changes the camera recenters on that place.
/// [accommodations] render as distinct stay markers (see [_StayPin]) that join
/// the auto-fit bounds but stay out of the route line and numbering.
///
/// With ≥2 [destinations] the map renders the trip-overview mode instead: one
/// numbered pin per destination (1..N in visit order) with the route line
/// walking the destinations — per-item pins, clustering, and travel-time
/// labels don't render there.
class TripMap extends StatefulWidget {
  final List<ItineraryItem> items;
  final int? selectedPosition;
  final void Function(int position)? onPinTap;

  /// Stays to plot alongside the itinerary. Entries without coordinates are
  /// skipped; the default keeps existing call sites unchanged.
  final List<Accommodation> accommodations;

  /// Label text (e.g. "12 min") for the within-city leg leaving the item at the
  /// given position. Drawn at the midpoint of that segment. Empty => no labels.
  final Map<int, String> segmentLabels;

  /// When this value changes (by `==`), the camera re-fits to the current
  /// trip extent after the next frame. Lets callers that filter [items] /
  /// [accommodations] upstream (e.g. a day-chip selection) reframe the view
  /// without remounting the map by key, which would flash tiles. The default
  /// (never changing) keeps existing call sites unchanged.
  final Object? fitSignature;

  /// Message shown when nothing is mappable (no items or stays with
  /// coordinates). Null — the default — uses the generic localized message,
  /// which keeps existing call sites unchanged.
  final String? emptyLabel;

  /// Optional second line under [emptyLabel] in the empty state.
  final String? emptyMessage;

  /// Optional CTA (e.g. an "Add place" button) rendered in the empty state.
  /// Null — the default, and what read-only screens pass — shows icon + text
  /// only.
  final Widget? emptyAction;

  /// Extra top camera-fit padding (px) for overlays floating on the map's top
  /// edge (e.g. [MapLegChips]), so fitted markers never land underneath them.
  /// The default keeps existing call sites unchanged.
  final double topOverlayInset;

  /// False renders a static preview: no gestures and no zoom/reset buttons.
  /// Callers overlay their own tap handler (e.g. tap-to-expand on phones).
  final bool interactive;

  /// Home-airport overlay: dashed outbound/return legs, a home pin, and the
  /// home point joining the camera fit. Null — the default, and what shared
  /// views pass — renders exactly as before.
  final TripMapHome? home;

  /// Trip-overview destination pins (see [TripMapDestination]). With ≥2
  /// entries the map renders one numbered pin per destination instead of
  /// per-item pins. Null or a shorter list — the default, day views, and
  /// single-city trips — keeps per-item pins, so existing call sites are
  /// unchanged.
  final List<TripMapDestination>? destinations;

  /// Opens the full-screen map. Non-null renders a fullscreen button beside
  /// the zoom/reset column when [interactive]; null — the default — keeps
  /// the control stack exactly as before.
  final VoidCallback? onExpand;

  const TripMap({
    super.key,
    required this.items,
    this.selectedPosition,
    this.onPinTap,
    this.segmentLabels = const {},
    this.accommodations = const [],
    this.fitSignature,
    this.emptyLabel,
    this.emptyMessage,
    this.emptyAction,
    this.topOverlayInset = 0,
    this.interactive = true,
    this.home,
    this.destinations,
    this.onExpand,
  });

  /// Whether [a] would render as a stay pin: geocoded (null means "not
  /// geocoded") and not the (0,0) junk sentinel. Public so screens can key
  /// their map-visibility gates to the exact filter the renderer applies.
  static bool stayHasCoords(Accommodation a) {
    final lat = a.latitude;
    final lng = a.longitude;
    return lat != null && lng != null && (lat != 0 || lng != 0);
  }

  @override
  State<TripMap> createState() => _TripMapState();
}

class _TripMapState extends State<TripMap> {
  final MapController _controller = MapController();

  /// Width from the previous layout, to catch resizes in [build]'s
  /// LayoutBuilder (they never reach [didUpdateWidget]).
  double? _lastMapWidth;

  /// [TripMap.selectedPosition], mirrored into a notifier (synced in
  /// [initState]/[didUpdateWidget]) so pins can render their selected state
  /// via [ValueListenableBuilder] WITHOUT the selection being baked into
  /// marker construction. The cluster layer decides whether to re-run full
  /// cluster-tree construction by an identity check on its marker list, so
  /// selection must never force a fresh list — see [_clusterMarkers].
  final ValueNotifier<int?> _selection = ValueNotifier<int?>(null);

  /// Cluster marker cache: valid while [TripMap.items] keeps its identity and
  /// the tappable flag is unchanged. `mapped` is a pure function of items, so
  /// items identity covers it. Returning the identical list makes the cluster
  /// package's `oldWidget.options.markers != widget.options.markers` check
  /// pass and skip re-clustering (selection changes, parent setStates).
  List<Marker>? _markerCache;
  List<ItineraryItem>? _markerCacheItems;
  bool _markerCacheTappable = false;

  @override
  void initState() {
    super.initState();
    _selection.value = widget.selectedPosition;
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  /// Fit padding shared by the initial fit and every re-fit; asymmetric so a
  /// top overlay (day chips) never covers the topmost fitted marker.
  EdgeInsets get _fitPadding =>
      EdgeInsets.fromLTRB(32, 32 + widget.topOverlayInset, 32, 32);

  static bool _hasCoords(ItineraryItem i) =>
      i.latitude != 0 || i.longitude != 0;

  /// Destination (trip-overview) mode: at least two pinnable destinations
  /// supplied. 0/1 entries — a single-city trip, or every destination
  /// ungeocoded — falls back to per-item pins so city trips keep place-level
  /// detail. The one home of the ≥2 rule, shared by [build] and the static
  /// fit-point mirror.
  static bool _destinationMode(List<TripMapDestination>? destinations) =>
      destinations != null && destinations.length >= 2;

  /// [TripMapHome] after the antimeridian guard documented on the class:
  /// legs spanning more than 180° of longitude (or with equal endpoints) are
  /// dropped, and when no drawable leg remains the whole overlay is
  /// suppressed — null here means "render no home pin and fit no home point".
  static TripMapHome? _effectiveHome(TripMapHome? home) {
    if (home == null) return null;
    bool drawable(LatLng? other) =>
        other != null &&
        other != home.point &&
        (other.longitude - home.point.longitude).abs() <= 180;
    final outboundTo = drawable(home.outboundTo) ? home.outboundTo : null;
    final returnFrom = drawable(home.returnFrom) ? home.returnFrom : null;
    if (outboundTo == null && returnFrom == null) return null;
    if (outboundTo == home.outboundTo && returnFrom == home.returnFrom) {
      return home;
    }
    return TripMapHome(
      point: home.point,
      label: home.label,
      outboundTo: outboundTo,
      returnFrom: returnFrom,
    );
  }

  /// Clockwise angle (radians) from screen-up to the segment a->b as rendered
  /// on the Web Mercator map, so a rotated up-arrow lies along the polyline.
  static double _bearing(LatLng a, LatLng b) {
    double mercY(double lat) =>
        math.log(math.tan(math.pi / 4 + lat * math.pi / 360));
    // Both deltas must be in radians for the angle to come out right.
    final dLng =
        (((b.longitude - a.longitude + 540) % 360) - 180) * math.pi / 180;
    return math.atan2(dLng, mercY(b.latitude) - mercY(a.latitude));
  }

  /// The coordinate of the currently selected itinerary item, if mappable.
  LatLng? _selectedPoint() {
    final sel = widget.selectedPosition;
    if (sel == null) return null;
    for (final it in widget.items) {
      if (it.position == sel && _hasCoords(it)) {
        return LatLng(it.latitude, it.longitude);
      }
    }
    return null;
  }

  /// Frames the camera on the whole trip, mirroring the initial fit in [build] so
  /// the reset button returns to the opening view. Called from a button tap when
  /// the controller is already live, so it runs synchronously (a post-frame
  /// deferral would not fire without a frame being scheduled).
  void _fitToTrip(List<LatLng> points) {
    if (points.isEmpty) return;
    try {
      if (points.length == 1) {
        _controller.move(points.first, 13);
      } else {
        _controller.fitCamera(
          AppCameraFitBounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: _fitPadding,
          ),
        );
      }
    } catch (_) {}
  }

  void _zoomBy(double delta) {
    try {
      _controller.move(
        _controller.camera.center,
        _controller.camera.zoom + delta,
      );
    } catch (_) {}
  }

  /// Every coordinate the camera should frame: destination pins (overview
  /// mode) or mapped items, plus geocoded stays, plus the home airport when
  /// its overlay has a visible leg (the camera must never stretch to a point
  /// nothing connects to). Mirrors the fitPoints assembled in [build]. Static
  /// so it can run against an oldWidget's lists in [didUpdateWidget].
  static List<LatLng> _fitPointsOf(
    List<TripMapDestination>? destinations,
    List<ItineraryItem> items,
    List<Accommodation> accommodations,
    LatLng? homePoint,
  ) {
    final points = <LatLng>[
      if (_destinationMode(destinations))
        for (final d in destinations!) d.point
      else
        for (final it in items)
          if (_hasCoords(it)) LatLng(it.latitude, it.longitude),
    ];
    for (final a in accommodations) {
      if (TripMap.stayHasCoords(a)) {
        points.add(LatLng(a.latitude!, a.longitude!));
      }
    }
    if (homePoint != null) points.add(homePoint);
    return points;
  }

  List<LatLng> _fitPoints() => _fitPointsOf(
        widget.destinations,
        widget.items,
        widget.accommodations,
        _effectiveHome(widget.home)?.point,
      );

  @override
  void didUpdateWidget(covariant TripMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signatureChanged = widget.fitSignature != oldWidget.fitSignature;
    // The set of mappable coordinates changed (a place added/removed/moved,
    // e.g. AI-streamed additions or a refresh delivering geocodes) while no
    // pin is selected: reframe so nothing sits off-screen. Order-insensitive
    // so a pure reorder never touches the camera. Skipped when the previous
    // frame had nothing mappable: build() then swaps the empty-state
    // Container for a freshly mounted FlutterMap whose initialCameraFit
    // already frames the new content.
    bool contentChanged() {
      if (widget.selectedPosition != null) return false;
      // The home comparison also covers the async case: the home overlay
      // flipping null → resolved (the IATA lookup completing after mount)
      // changes the fit-point set, so the camera refits to include home.
      final oldPoints = _fitPointsOf(
        oldWidget.destinations,
        oldWidget.items,
        oldWidget.accommodations,
        _effectiveHome(oldWidget.home)?.point,
      );
      if (oldPoints.isEmpty) return false;
      return !setEquals(_fitPoints().toSet(), oldPoints.toSet());
    }

    if (signatureChanged || contentChanged()) {
      // Re-fit after the frame that renders the new (filtered) content, so
      // the controller sees the updated layout. No-op when nothing is
      // mappable (the empty state has no live map to move).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _fitToTrip(_fitPoints());
      });
    }
    // Keep the pins' selection notifier in sync (ValueNotifier drops
    // same-value writes, so this is free when selection didn't change).
    _selection.value = widget.selectedPosition;
    if (widget.selectedPosition != null &&
        widget.selectedPosition != oldWidget.selectedPosition) {
      final target = _selectedPoint();
      if (target == null) return;
      // Defer until after layout so the map controller is ready; zoom in enough
      // to break the place out of any marker cluster.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        var zoom = 15.0;
        try {
          zoom = _controller.camera.zoom < 15 ? 15 : _controller.camera.zoom;
        } catch (_) {}
        _controller.move(target, zoom);
      });
    }
  }

  /// The per-item cluster markers, cached by [TripMap.items] identity (see
  /// the cache fields above). Pin visuals read the selection from
  /// [_selection] via [ValueListenableBuilder] and the tap closure derefs
  /// `widget.onPinTap` lazily, so a cached marker never captures stale
  /// state — the cache key is only (items identity, tappable-or-not).
  ///
  /// Labels count 1..N over what this map view shows (the whole trip on All,
  /// one day on Day N) — not the item's trip-wide position, which reads as
  /// arbitrary once the view filters or skips ungeocoded items.
  List<Marker> _clusterMarkers(
      List<({ItineraryItem item, LatLng point})> mapped) {
    final tappable = widget.onPinTap != null;
    if (_markerCache != null &&
        identical(_markerCacheItems, widget.items) &&
        _markerCacheTappable == tappable) {
      return _markerCache!;
    }
    final markers = <Marker>[
      for (final (k, m) in mapped.indexed)
        Marker(
          point: m.point,
          // Transparent 44px halo around the 24/28px dot, tap handling on
          // the whole box; centered so the dot stays anchored on its
          // coordinate (see _pinHitBox).
          width: _pinHitBox,
          height: _pinHitBox,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: tappable ? () => widget.onPinTap!(m.item.position) : null,
            child: Center(
              child: ValueListenableBuilder<int?>(
                valueListenable: _selection,
                builder: (context, sel, _) {
                  final selected = sel == m.item.position;
                  return SizedBox.square(
                    dimension: selected ? 28 : 24,
                    child: _Pin(
                      label: '${k + 1}',
                      category: m.item.category,
                      selected: selected,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
    ];
    _markerCacheItems = widget.items;
    _markerCacheTappable = tappable;
    _markerCache = markers;
    return markers;
  }

  /// Test hook: the current cluster marker list, or null before first build.
  /// Lets tests assert selection changes and view-only parent rebuilds keep
  /// the identical list (no re-cluster) while an items swap produces a new
  /// one.
  @visibleForTesting
  List<Marker>? get debugClusterMarkerCache => _markerCache;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    final mapped = <({ItineraryItem item, LatLng point})>[];
    for (final it in widget.items) {
      if (_hasCoords(it)) {
        mapped.add((item: it, point: LatLng(it.latitude, it.longitude)));
      }
    }

    // Stays with real coordinates (null means "not geocoded"; 0,0 is junk).
    final stays = <({Accommodation stay, LatLng point})>[];
    for (final a in widget.accommodations) {
      if (TripMap.stayHasCoords(a)) {
        stays.add((stay: a, point: LatLng(a.latitude!, a.longitude!)));
      }
    }

    final destMode = _destinationMode(widget.destinations);

    // Destination mode always has ≥2 route points to show, even when a
    // category lens empties the day-filtered items.
    if (mapped.isEmpty && stays.isEmpty && !destMode) {
      return Container(
        color: theme.colorScheme.surfaceContainerHighest,
        // Keep the centered content clear of the day-chip band's *visible*
        // pills. Deliberately capped below the full camera-fit inset: that
        // one also covers the band's transparent hit halo, which static
        // empty-state text can safely sit under — and the fixed-height
        // inline map cards don't have the room (EmptyState would overflow
        // at 240px).
        padding: EdgeInsets.only(
          top: math.min(widget.topOverlayInset, _emptyStateTopInset),
        ),
        child: EmptyState(
          compact: true,
          icon: Icons.location_off_outlined,
          title: widget.emptyLabel ?? l10n.mapNoMappedPlaces,
          message: widget.emptyMessage,
          actions: [if (widget.emptyAction != null) widget.emptyAction!],
        ),
      );
    }

    // The route walks the destinations (city legs) in overview mode,
    // per-item points otherwise; pins, polyline, and arrows all follow it.
    final routePoints = destMode
        ? [for (final d in widget.destinations!) d.point]
        : mapped.map((m) => m.point).toList();
    final home = _effectiveHome(widget.home);
    // Camera framing covers stays and the home airport too; the route
    // polyline sticks to [routePoints].
    final fitPoints = [
      ...routePoints,
      for (final s in stays) s.point,
      if (home != null) home.point,
    ];
    final selected = _selectedPoint();

    // Home-airport legs (outbound home → first city, return last city →
    // home). Kept out of [mapped]/[routePoints]: appending there would
    // silently reindex the numbered pins and break segment-label adjacency,
    // so the legs get their own dashed polylines and arrow markers below.
    final homeSegments = <({LatLng a, LatLng b})>[
      if (home != null && home.outboundTo != null)
        (a: home.point, b: home.outboundTo!),
      if (home != null && home.returnFrom != null)
        (a: home.returnFrom!, b: home.point),
    ];

    // Travel-time labels at the midpoint of each within-city leg (only between
    // truly adjacent itinerary stops that are both mapped). Kept as endpoint
    // records — _SegmentLabelLayer decides per camera frame which are visible.
    // Destination mode has none: segmentLabels hold within-city legs by
    // construction, and the overview draws only city→city legs.
    final labelSegments = <({LatLng a, LatLng b, String text})>[];
    if (!destMode) {
      for (var k = 0; k < mapped.length - 1; k++) {
        final a = mapped[k];
        final b = mapped[k + 1];
        if (b.item.position != a.item.position + 1) continue;
        final label = widget.segmentLabels[a.item.position];
        if (label == null) continue;
        labelSegments.add((a: a.point, b: b.point, text: label));
      }
    }

    // Direction arrows on every drawn segment (each consecutive pair of route
    // points, matching the polyline). Placed at the midpoint, or further along
    // when a travel-time label already occupies the midpoint. Placement stays
    // static even though labels hide dynamically on short legs: on such a leg
    // (< _SegmentLabelLayer.minLegPx on screen) t=0.7 vs 0.5 differs by a few
    // px and the arrow tucks behind the pins anyway. In destination mode
    // [routePoints] and [mapped] no longer align, so the label lookup (an
    // item-mode concept) must not touch [mapped] there.
    final arrowMarkers = <Marker>[];
    for (var k = 0; k < routePoints.length - 1; k++) {
      final a = routePoints[k];
      final b = routePoints[k + 1];
      if (a == b) continue;
      final hasLabel = !destMode &&
          mapped[k + 1].item.position == mapped[k].item.position + 1 &&
          widget.segmentLabels[mapped[k].item.position] != null;
      final t = hasLabel ? 0.7 : 0.5;
      arrowMarkers.add(
        Marker(
          point: LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          ),
          width: 18,
          height: 18,
          child: _SegmentArrow(angle: _bearing(a, b)),
        ),
      );
    }
    // Home legs carry no travel-time labels, so their arrow always sits at
    // the midpoint.
    for (final s in homeSegments) {
      arrowMarkers.add(
        Marker(
          point: LatLng(
            (s.a.latitude + s.b.latitude) / 2,
            (s.a.longitude + s.b.longitude) / 2,
          ),
          width: 18,
          height: 18,
          child: _SegmentArrow(angle: _bearing(s.a, s.b)),
        ),
      );
    }

    // Wheel scroll stays with the page (the map lives inside a ListView);
    // zooming is done via the on-map buttons or touch pinch.
    final interaction = widget.interactive
        ? const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
          )
        : const InteractionOptions(flags: InteractiveFlag.none);

    // The zoom floor that keeps the single world filling the box depends on
    // the width the map is given, so the options are assembled in a
    // LayoutBuilder.
    return LayoutBuilder(
      builder: (context, constraints) {
        final minZoom = appMapMinZoomFor(constraints.maxWidth);

        // flutter_map adopts a changed minZoom into the camera's options but
        // never re-clamps the live zoom, so after a resize nudge the camera
        // back over the (possibly risen) floor. One move covers both resize
        // failure modes: moveRaw re-applies clampZoom *and* the camera
        // constraint, and no-ops when nothing is out of bounds.
        if (_lastMapWidth != null && _lastMapWidth != constraints.maxWidth) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            try {
              final camera = _controller.camera;
              _controller.move(camera.center, math.max(camera.zoom, minZoom));
            } catch (_) {}
          });
        }
        _lastMapWidth = constraints.maxWidth;

        // Center on the selected place when one is set (e.g. the map was just
        // (re)built after a list tap); otherwise fit the whole trip.
        final MapOptions options = selected != null
            ? appMapOptions(
                initialCenter: selected,
                initialZoom: 15,
                minZoom: minZoom,
                interactionOptions: interaction,
              )
            : fitPoints.length == 1
                // Single point: bounds collapse, so center with a sensible zoom.
                ? appMapOptions(
                    initialCenter: fitPoints.first,
                    initialZoom: 13,
                    minZoom: minZoom,
                    interactionOptions: interaction,
                  )
                : appMapOptions(
                    initialCameraFit: AppCameraFitBounds(
                      bounds: LatLngBounds.fromPoints(fitPoints),
                      padding: _fitPadding,
                    ),
                    minZoom: minZoom,
                    interactionOptions: interaction,
                  );

        return Stack(
          children: [
            FlutterMap(
              mapController: _controller,
              options: options,
              children: [
                ...appMapTileLayers(context),
                if (routePoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      // Two passes make a thin line with a soft glow that stays
                      // legible over satellite imagery.
                      Polyline(
                        points: routePoints,
                        strokeWidth: 6,
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                      Polyline(
                        points: routePoints,
                        strokeWidth: 2,
                        color: Colors.white.withValues(alpha: 0.95),
                      ),
                    ],
                  ),
                if (homeSegments.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      for (final s in homeSegments) ...[
                        // Same two-pass glow as the route line, but dashed:
                        // these legs are travel to/from the trip, not part of
                        // the itinerary walk.
                        Polyline(
                          points: [s.a, s.b],
                          strokeWidth: 6,
                          color: Colors.white.withValues(alpha: 0.25),
                          pattern: StrokePattern.dashed(
                            segments: const [8, 6],
                          ),
                        ),
                        Polyline(
                          points: [s.a, s.b],
                          strokeWidth: 2,
                          color: Colors.white.withValues(alpha: 0.95),
                          pattern: StrokePattern.dashed(
                            segments: const [8, 6],
                          ),
                        ),
                      ],
                    ],
                  ),
                if (arrowMarkers.isNotEmpty) MarkerLayer(markers: arrowMarkers),
                if (labelSegments.isNotEmpty)
                  _SegmentLabelLayer(segments: labelSegments),
                // The home airport, like stays, sits outside the clusterer
                // and beneath the numbered pins: it is a fixed journey
                // endpoint, not an itinerary stop.
                if (home != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: home.point,
                        // Transparent 44px halo around the 26px body; the box
                        // stays centered on the coordinate (see _pinHitBox).
                        width: _pinHitBox,
                        height: _pinHitBox,
                        child: _HomePin(
                          message: l10n.mapHomeAirport(home.label),
                        ),
                      ),
                    ],
                  ),
                // Stays live in their own layer, outside the clusterer: a trip has
                // few of them and "where am I sleeping" should never collapse into
                // an anonymous count bubble with sightseeing pins. Drawn beneath
                // the numbered pins so the primary interaction stays on top.
                if (stays.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      for (final s in stays)
                        Marker(
                          point: s.point,
                          // Transparent 44px halo around the 26px square; the
                          // box stays centered on the coordinate (see
                          // _pinHitBox).
                          width: _pinHitBox,
                          height: _pinHitBox,
                          child: _StayPin(
                            name: s.stay.name,
                            dates: tripDateRange(
                              s.stay.checkIn,
                              s.stay.checkOut,
                            ),
                          ),
                        ),
                    ],
                  ),
                if (destMode)
                  // Trip overview: one numbered pin per destination (city
                  // leg), 1..N in visit order — a plain layer, never
                  // clustered: a count bubble here reads as a bogus route
                  // number at world zoom.
                  MarkerLayer(
                    markers: [
                      for (final (k, d) in widget.destinations!.indexed)
                        Marker(
                          point: d.point,
                          // Transparent 44px halo around the 24px dot; the
                          // box stays centered on the coordinate (see
                          // _pinHitBox).
                          width: _pinHitBox,
                          height: _pinHitBox,
                          child: _DestinationPin(
                            label: '${k + 1}',
                            name: d.label,
                            dates: d.dates,
                          ),
                        ),
                    ],
                  )
                else
                  MarkerClusterLayerWidget(
                    options: MarkerClusterLayerOptions(
                      maxClusterRadius: 45,
                      size: const Size(32, 32),
                      padding: const EdgeInsets.all(40),
                      markers: _clusterMarkers(mapped),
                      builder: (context, clusterMarkers) =>
                          _ClusterBubble(count: clusterMarkers.length),
                    ),
                  ),
                appMapAttribution(),
              ],
            ),
            if (widget.interactive)
              Positioned(
                right: 8,
                bottom: 8,
                // The expand button sits beside the zoom column, not above
                // it: stacked, the strip would reach into the day-chip band
                // on the 240px inline card.
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (widget.onExpand != null) ...[
                      MapControlButton(
                        icon: Icons.fullscreen,
                        tooltip: l10n.tripExpandMap,
                        onTap: widget.onExpand!,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MapControlButton(
                          icon: Icons.add,
                          tooltip: l10n.mapZoomIn,
                          onTap: () => _zoomBy(1),
                        ),
                        const SizedBox(height: 8),
                        MapControlButton(
                          icon: Icons.remove,
                          tooltip: l10n.mapZoomOut,
                          onTap: () => _zoomBy(-1),
                        ),
                        const SizedBox(height: 8),
                        MapControlButton(
                          icon: Icons.zoom_in_map,
                          tooltip: l10n.mapResetMap,
                          onTap: () => _fitToTrip(fitPoints),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// An arrow on a route segment showing the direction of travel. [angle] is
/// clockwise radians from screen-up; the marker keeps the default
/// rotate-with-map behavior so the arrow stays aligned with the polyline.
class _SegmentArrow extends StatelessWidget {
  final double angle;
  const _SegmentArrow({required this.angle});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: const Icon(
        Icons.navigation,
        size: 14,
        color: Colors.white,
        shadows: [
          Shadow(color: Colors.black54, blurRadius: 3),
          Shadow(color: Colors.black54, blurRadius: 6),
        ],
      ),
    );
  }
}

/// Renders travel-time pills only for legs long enough on screen to have room
/// for one — zoomed out, same-city stops converge and the midpoint pill would
/// just sit behind the numbered pins. Rebuilds on every camera move/zoom
/// because MapCamera.of registers an InheritedModel dependency.
class _SegmentLabelLayer extends StatelessWidget {
  /// Minimum on-screen leg length (px) before its pill is drawn: pin radius
  /// (12-14) + half a typical pill (~23×11) + breathing room, per side.
  static const double minLegPx = 70;

  final List<({LatLng a, LatLng b, String text})> segments;
  const _SegmentLabelLayer({required this.segments});

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final markers = <Marker>[
      for (final s in segments)
        if ((camera.latLngToScreenOffset(s.a) -
                    camera.latLngToScreenOffset(s.b))
                .distance >=
            minLegPx)
          Marker(
            point: LatLng(
              (s.a.latitude + s.b.latitude) / 2,
              (s.a.longitude + s.b.longitude) / 2,
            ),
            width: 84,
            height: 26,
            child: _SegmentLabel(text: s.text),
          ),
    ];
    if (markers.isEmpty) return const SizedBox.shrink();
    return MarkerLayer(markers: markers);
  }
}

/// A small pill showing a leg's travel time, centered on the route line.
class _SegmentLabel extends StatelessWidget {
  final String text;
  const _SegmentLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          // Shared over-map scrim so the time reads cleanly over satellite
          // imagery and the route line beneath it (same treatment as the day
          // chips and control buttons).
          color: AppColors.mapScrim,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ClusterBubble extends StatelessWidget {
  final int count;
  const _ClusterBubble({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// The painted itinerary dot. Purely visual: tap handling lives on the
/// marker-level GestureDetector so the whole [_pinHitBox] halo is tappable.
class _Pin extends StatelessWidget {
  final String label;
  final String? category;
  final bool selected;

  /// Overrides the category tint ([_DestinationPin]: one consistent color).
  final Color? color;

  const _Pin({
    required this.label,
    required this.category,
    required this.selected,
    this.color,
  });

  Color _color(ColorScheme scheme) =>
      color ?? AppColors.forCategory(category, scheme);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _color(scheme);
    return Container(
      // A permanent white ring keeps the small dots crisp over satellite
      // imagery; selection thickens the ring (and the dot itself grows).
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: selected ? 3 : 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: selected ? 0.5 : 0.35),
            blurRadius: selected ? 6 : 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// A destination (city-leg) pin for the trip-overview mode: the same round
/// numbered dot as itinerary pins, in one consistent color (category tinting
/// is meaningless for a whole city). Destinations sit outside the
/// position-based selection sync, so a tap shows a self-contained tooltip
/// (city + dates) like [_StayPin] instead of driving [TripMap.onPinTap].
class _DestinationPin extends StatelessWidget {
  /// The 1..N visit-order ordinal shown in the dot.
  final String label;

  /// Display city for the tooltip, already localized by the caller.
  final String name;

  /// Pre-formatted date range; null shows the name alone.
  final String? dates;

  const _DestinationPin({
    required this.label,
    required this.name,
    this.dates,
  });

  @override
  Widget build(BuildContext context) {
    // The tooltip's tap detector fills the marker's [_pinHitBox] box, so the
    // whole transparent halo around the 24px dot triggers it.
    return Tooltip(
      message: dates == null ? name : '$name\n$dates',
      triggerMode: TooltipTriggerMode.tap,
      child: Center(
        child: SizedBox.square(
          dimension: 24,
          child: _Pin(
            label: label,
            category: null,
            selected: false,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// The home-airport marker: a rounded square with a takeoff glyph in the
/// flights accent color — same family treatment as [_StayPin] (white ring,
/// shadow, square-not-round), distinct from both stays and itinerary dots.
/// Tap shows a self-contained tooltip ("Home airport (EWR)").
class _HomePin extends StatelessWidget {
  /// Pre-localized tooltip text.
  final String message;

  const _HomePin({required this.message});

  @override
  Widget build(BuildContext context) {
    // The tooltip's tap detector fills the marker's [_pinHitBox] box, so the
    // whole transparent halo around the 26px square triggers it.
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      child: Center(
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: AppColors.toolFlights,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.flight_takeoff,
            size: 14,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// A stay (accommodation) marker: a rounded square with a bed glyph in the
/// stays accent color, deliberately unlike the circular numbered itinerary
/// pins. Stays sit outside the position-based selection sync, so a tap shows
/// a self-contained tooltip (name + dates) instead of driving [TripMap.onPinTap].
class _StayPin extends StatelessWidget {
  final String name;

  /// Pre-formatted check-in – check-out range; null when dates are missing.
  final String? dates;

  const _StayPin({required this.name, this.dates});

  @override
  Widget build(BuildContext context) {
    // The tooltip's tap detector fills the marker's [_pinHitBox] box, so the
    // whole transparent halo around the 26px square triggers it.
    return Tooltip(
      message: dates == null ? name : '$name\n$dates',
      triggerMode: TooltipTriggerMode.tap,
      child: Center(
        child: Container(
          width: 26,
          height: 26,
          // Same white ring + shadow treatment as _Pin so it reads as part
          // of the family, but square where itinerary pins are round.
          decoration: BoxDecoration(
            color: AppColors.toolAirbnb,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.hotel, size: 14, color: Colors.white),
        ),
      ),
    );
  }
}
