import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';
import 'app_map.dart';
import 'stat_tile_row.dart';

/// The "Your travels" block on the trips list: a world map pinning every hub
/// city across the user's owned trips, with lifetime stat tiles beneath — the
/// retrospective bridge between the Upcoming cards above it and the Past
/// section below. One merged card (not separate stats + map bands) so the
/// sparse one-trip-each-way page gains a single substantial scroll stop, and
/// so the whole block shares one gating story: with no located cities the map
/// sub-band collapses and the card degrades to a labeled stats strip.
///
/// Neutral [Card] chrome on purpose — the brand gradient stays reserved for
/// the two promoted cards (live spotlight, "Up next" hero). Pins come from
/// the list payload (footprintPins over Trip.cityPins), never from the
/// per-trip detail cache — unlike TripMapBand this band must render for
/// trips never opened on this device.
class TravelFootprintCard extends StatelessWidget {
  final List<({String city, double lat, double lng})> pins;
  final ({int trips, int travelDays, int cities}) stats;

  const TravelFootprintCard({
    super.key,
    required this.pins,
    required this.stats,
  });

  /// Slightly shorter than TripMapBand's 160 hero band so the retrospective
  /// card never outweighs the "Up next" hero above it.
  static const double _bandHeight = 140;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Zero-valued tiles drop out segment-wise (undated trips contribute no
    // travel days, city-less legacy rows no cities), same rule the old
    // upcoming-only stats line used. Trips is never zero here — the caller
    // gates the card on >= 2 owned trips.
    final tiles = [
      StatTileData(
        value: '${stats.trips}',
        label: l10n.tripsListStatTrips(stats.trips),
      ),
      if (stats.travelDays > 0)
        StatTileData(
          value: '${stats.travelDays}',
          label: l10n.tripsListStatTravelDays(stats.travelDays),
        ),
      if (stats.cities > 0)
        StatTileData(
          value: '${stats.cities}',
          label: l10n.tripsListStatCities(stats.cities),
        ),
    ];
    return Card(
      // The map tiles paint square corners; the card's own clip rounds them.
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pins.isNotEmpty)
            SizedBox(
              height: _bandHeight,
              child: Semantics(
                label: l10n.tripsListTravelMap,
                child: _FootprintMap(pins: pins),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // In-card header (not a page-level SectionHeader): a third
                // header tier between "Upcoming" and "Past trips" would read
                // as clutter, and the label must stay attached when the map
                // collapses.
                Row(
                  children: [
                    Icon(Icons.public,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      l10n.tripsListYourTravels,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                StatTileRow(tiles: tiles),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The footprint's map band: single-world satellite via the app_map
/// primitives, a scatter of unnumbered city dots (a footprint has no visit
/// order — TripMap's numbered pins + route line are the wrong idiom), camera
/// fit once over all pins. Static camera: a mid-list band that pans would
/// steal the page's scroll gesture. Pins keep tap-tooltips ("what city is
/// that?" costs nothing), which is also why there is no AbsorbPointer and no
/// ExcludeSemantics — the tooltips carry the city names for screen readers.
class _FootprintMap extends StatefulWidget {
  final List<({String city, double lat, double lng})> pins;

  const _FootprintMap({required this.pins});

  @override
  State<_FootprintMap> createState() => _FootprintMapState();
}

class _FootprintMapState extends State<_FootprintMap> {
  /// Marker box: transparent halo padding the 12px dot to the 44px touch
  /// minimum, centered on the coordinate (the trip_map hit-box idiom).
  static const double _pinHitBox = 44;

  final MapController _controller = MapController();
  double? _lastMapWidth;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final points = [
      for (final p in widget.pins) LatLng(p.lat, p.lng),
    ];
    // The zoom floor that keeps the single world filling the box depends on
    // the width the map is given, so the options are assembled in a
    // LayoutBuilder (the TripMap pattern).
    return LayoutBuilder(
      builder: (context, constraints) {
        final minZoom = appMapMinZoomFor(constraints.maxWidth);

        // flutter_map adopts a changed minZoom into the camera's options but
        // never re-clamps the live zoom, so after a resize nudge the camera
        // back over the (possibly risen) floor — same recovery TripMap does.
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

        final options = points.length == 1
            // Single city (bounds collapse): continental context, not
            // TripMap's street-level 13 — a footprint locates cities on the
            // globe, it doesn't tour one.
            ? appMapOptions(
                initialCenter: points.first,
                initialZoom: 4,
                minZoom: minZoom,
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
              )
            : appMapOptions(
                initialCameraFit: AppCameraFitBounds(
                  bounds: LatLngBounds.fromPoints(points),
                  padding: const EdgeInsets.all(24),
                ),
                minZoom: minZoom,
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
              );

        return FlutterMap(
          mapController: _controller,
          options: options,
          children: [
            ...appMapTileLayers(context),
            MarkerLayer(
              markers: [
                for (final p in widget.pins)
                  Marker(
                    point: LatLng(p.lat, p.lng),
                    width: _pinHitBox,
                    height: _pinHitBox,
                    child: _FootprintPin(city: p.city),
                  ),
              ],
            ),
            appMapAttribution(),
          ],
        );
      },
    );
  }
}

/// An unnumbered city dot: the _Pin family's white-ring-and-shadow treatment
/// over satellite imagery, brand primary, no ordinal. The tooltip's tap
/// detector fills the marker's hit box, so the whole transparent halo around
/// the 12px dot triggers it.
class _FootprintPin extends StatelessWidget {
  final String city;

  const _FootprintPin({required this.city});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: city,
      triggerMode: TooltipTriggerMode.tap,
      child: Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
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
        ),
      ),
    );
  }
}
