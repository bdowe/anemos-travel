import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_shadows.dart';
import '../theme/spacing.dart';
import '../utils/trip_list_insights.dart';
import 'stat_tile_row.dart';

/// The two pieces the trips-list footprint band and the travel atlas both
/// paint. They live here rather than privately inside `travel_footprint_card`
/// because the atlas needs the SAME treatment on a different surface, and a
/// second copy of either would drift: the dot's filled-vs-hollow reading is
/// the map's whole legend, and the group's label weight is what keeps the
/// caption quieter than the section header above it.
///
/// The maps themselves are deliberately not shared. The band's camera is
/// static (a panning map mid-scroll steals the page's scroll gesture) while
/// the atlas is pan-and-zoom; one widget with an interaction flag would hide
/// that difference rather than state it.

/// An unnumbered city dot: the _Pin family's white-ring-and-shadow treatment
/// over satellite imagery, brand primary, no ordinal.
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
class FootprintDot extends StatelessWidget {
  /// The dot's painted diameter. The marker box around it is much larger (the
  /// 44px hit-box idiom); this is only the ink.
  static const double size = 12;

  final bool visited;

  const FootprintDot({super.key, required this.visited});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: visited ? primary : Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          // The trip_map pin family's shared drop, and this dot is one of that
          // family — the token's own dartdoc names this use.
          boxShadow: AppShadows.pin,
        ),
      ),
    );
  }
}

/// One labeled side of the traveled/planned split: a quiet title over the
/// group's stat line.
///
/// The label is **sentence case** — the same l10n string labels the map's pin
/// tooltips ("Kraków · Planned"), and one string beats a second key plus a
/// locale-unsafe toUpperCase(). It must also read quieter than the page-level
/// heading above it: header > group label > stats. It carried UpNextTripCard's
/// letterspaced treatment until the editorial pass; a letterspaced label above
/// a heading is an eyebrow in everything but name, and the brand rulebook
/// allows exactly one of those (the place eyebrow on destination surfaces).
/// Weight does the work here instead.
class TravelStatGroup extends StatelessWidget {
  final String label;
  final TravelStats stats;

  const TravelStatGroup({super.key, required this.label, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Zero-valued tiles drop out segment-wise (undated trips contribute no
    // travel days, city-less legacy rows no cities), the rule this caption has
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
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        StatTileRow(tiles: tiles),
      ],
    );
  }
}
