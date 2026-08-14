import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';
import '../utils/trip_list_insights.dart';
import 'app_map.dart';
import 'stat_tile_row.dart';

/// Handles for the two stat groups. Locale-free on purpose: "is the traveled
/// group on screen?" is the invariant this card turns on, and a test that
/// asked by label would answer it differently in Spanish.
const kTraveledStatsKey = ValueKey('travelStats.traveled');
const kPlannedStatsKey = ValueKey('travelStats.planned');

/// The body of the "Your travels" section on the trips list: a world map
/// pinning every hub city across the user's owned trips, with the travel stat
/// tiles beneath. One merged card (not separate stats + map bands) so the
/// sparse one-trip-each-way page gains a single substantial scroll stop, and
/// so the whole block shares one gating story: with no located cities the map
/// sub-band collapses and the card degrades to a bare stats strip.
///
/// **Traveled and planned are separate, labeled groups**, and the map says
/// which pins are which (filled = been there, hollow = still ahead). The band
/// reported one all-time total until 2026-08-14, which counted a trip starting
/// next month as travel already taken — 40 "travel days" when 2 had happened.
/// This card sits exactly where the page turns from plans to history, so its
/// numbers have to name which of the two they are. A group whose trip count is
/// zero does not render at all: that one rule is why a brand-new planner never
/// meets a row of zeros, and why nothing here needs a second display mode.
///
/// **Unlabeled by design** — the "Your travels" title is a page-level
/// SectionHeader the caller renders directly above, under the same gate.
/// This card carried its own in-card header until 2026-08-14; that read as
/// clutter-avoidance at the time but cost more than it saved, because a map
/// over an info panel IS the "Up next" hero's silhouette. With the only label
/// tucked *under* the map, the eye hit an unlabeled map inside a run of trip
/// cards and parsed the whole thing as another upcoming trip. A section's
/// label has to sit outside and above its visual, not inside it.
///
/// Neutral [Card] chrome on purpose — the brand gradient stays reserved for
/// the two promoted cards (live spotlight, "Up next" hero). Pins come from
/// the list payload (footprintPins over Trip.cityPins), never from the
/// per-trip detail cache — unlike TripMapBand this band must render for
/// trips never opened on this device.
class TravelFootprintCard extends StatelessWidget {
  final List<FootprintPin> pins;
  final TravelStats traveled;
  final TravelStats planned;

  const TravelFootprintCard({
    super.key,
    required this.pins,
    required this.traveled,
    required this.planned,
  });

  /// Slightly shorter than TripMapBand's 160 hero band so the retrospective
  /// card never outweighs the "Up next" hero above it.
  static const double _bandHeight = 140;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Every trip lands on exactly one side (travelStats), and the caller gates
    // the card on >= 2 owned trips, so at least one group always survives.
    final groups = [
      if (traveled.trips > 0)
        (
          key: kTraveledStatsKey,
          label: l10n.tripsListStatsTraveled,
          stats: traveled,
        ),
      if (planned.trips > 0)
        (
          key: kPlannedStatsKey,
          label: l10n.tripsListStatsPlanned,
          stats: planned,
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
                child: _FootprintMap(
                  pins: pins,
                  tooltipFor: (p) => '${p.city} · '
                      '${p.visited ? l10n.tripsListStatsTraveled : l10n.tripsListStatsPlanned}',
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < groups.length; i++) ...[
                  // xl, not md: an eyebrow sits ~26px above its own numbers,
                  // so a 12px seam left it equidistant between the two groups
                  // and it read as floating between them rather than heading
                  // the one below. A group label has to be nearer its group
                  // than its neighbour by a visible margin.
                  if (i > 0) const SizedBox(height: AppSpacing.xl),
                  _StatGroup(
                    key: groups[i].key,
                    label: groups[i].label,
                    stats: groups[i].stats,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One labeled side of the split: a quiet eyebrow over the shared stat tiles.
///
/// The eyebrow borrows UpNextTripCard's treatment but stays **sentence case**
/// where that one is caps — the same l10n string labels the map's pin tooltips
/// ("Kraków · Planned"), and one string beats a second key plus a
/// locale-unsafe toUpperCase(). It must also read quieter than the page-level
/// "Your travels" SectionHeader above the card: header > eyebrow > tile label.
class _StatGroup extends StatelessWidget {
  final String label;
  final TravelStats stats;

  const _StatGroup({super.key, required this.label, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Zero-valued tiles drop out segment-wise (undated trips contribute no
    // travel days, city-less legacy rows no cities), the rule this card has
    // always used. Trips is never zero — the caller drops the whole group.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        StatTileRow(tiles: tiles),
      ],
    );
  }
}

/// The footprint's map band: single-world satellite via the app_map
/// primitives, a scatter of unnumbered city dots (a footprint has no visit
/// order — TripMap's numbered pins + route line are the wrong idiom), camera
/// fit once over all pins. Static camera: a mid-list band that pans would
/// steal the page's scroll gesture. Pins keep tap-tooltips ("what city is
/// that?" costs nothing), which is also why there is no AbsorbPointer and no
/// ExcludeSemantics — the tooltips carry the city names for screen readers,
/// and now the traveled/planned state too: the two dot styles are the fast
/// read, the tooltip is the one that can't be misread.
class _FootprintMap extends StatefulWidget {
  final List<FootprintPin> pins;
  final String Function(FootprintPin) tooltipFor;

  const _FootprintMap({required this.pins, required this.tooltipFor});

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
                    child: _FootprintPin(
                      tooltip: widget.tooltipFor(p),
                      visited: p.visited,
                    ),
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
///
/// [visited] changes only the FILL — brand primary for a city already
/// travelled, hollow (a dark translucent core) for one still ahead: the
/// filled-vs-empty idiom, and the same reading as a ticked box. The white ring
/// and shadow stay on both so the two are equally findable on busy imagery.
///
/// Swapping the ring colour instead was tried first and inverted the emphasis:
/// at 12px a primary ring on a white core just reads "white dot", which shouts
/// louder than the teal one — the trips you HAVEN'T taken became the loud
/// pins in a section headed by the ones you have. Both stay hardcoded white
/// rather than a surface token: these sit on satellite imagery, which looks
/// the same in either app theme, so a theme-following ring would vanish.
class _FootprintPin extends StatelessWidget {
  final String tooltip;
  final bool visited;

  const _FootprintPin({required this.tooltip, required this.visited});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.tap,
      child: Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: visited ? primary : Colors.black.withValues(alpha: 0.35),
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
