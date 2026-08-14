import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/trip.dart';
import '../providers/recent_trip_provider.dart';
import '../theme/spacing.dart';
import '../utils/leg_ranges.dart';
import 'trip_map.dart';
import 'trip_map_destinations.dart';

/// A gradient card's map band: the cached trip's overview map (numbered
/// destination pins + route line, the trip-detail visual) rendered as a
/// static preview above the card's title row. Collapses to nothing while the
/// cache read resolves, on a miss (MRU eviction, fresh device), and when
/// nothing on the trip is mappable — the host card then renders exactly as it
/// would without the band. Fed by [cachedTripDetailProvider], so it is
/// cache-ONLY: the band decorates what other screens loaded, it never
/// fetches. Hosts: Home's recent-trip card and the trips list's "Up next"
/// hero.
class TripMapBand extends ConsumerStatefulWidget {
  final String tripId;

  /// Band height. The 160 default is slightly shorter than the trip-detail
  /// phone preview (180) so a hosting card doesn't dominate its fold.
  final double height;

  const TripMapBand({super.key, required this.tripId, this.height = 160});

  @override
  ConsumerState<TripMapBand> createState() => _TripMapBandState();
}

class _TripMapBandState extends ConsumerState<TripMapBand> {
  /// Derived-list memo, keyed the TripDerivation.matches way: identity on the
  /// cached Trip and the localizations object (a locale switch delivers a new
  /// instance and re-labels the pins). Stable list identities across host
  /// rebuilds keep TripMap's identity-keyed caches valid.
  Trip? _memoTrip;
  AppLocalizations? _memoL10n;
  List<TripMapDestination> _destinations = const [];
  List<Accommodation> _stays = const [];
  bool _mappable = false;

  void _recompute(Trip trip, AppLocalizations l10n) {
    if (identical(trip, _memoTrip) && identical(l10n, _memoL10n)) return;
    _memoTrip = trip;
    _memoL10n = l10n;
    // Confirmed stays only — the same !auto rule as the trip screen: a
    // suggested draft's dates/position are themselves derived, so it must
    // not render as a real stay pin.
    _stays = [
      for (final a in trip.accommodations ?? const <Accommodation>[])
        if (!a.auto) a
    ];
    _destinations = tripMapDestinations(rawLegRanges(trip), l10n);
    // Mirrors the trip-detail derivation's mapShown gate: mount the map only
    // when something would actually plot — TripMap's light empty-state box
    // is the wrong surface inside a brand-gradient card.
    _mappable = (trip.items ?? const [])
            .any((i) => i.latitude != 0 || i.longitude != 0) ||
        _stays.any(TripMap.stayHasCoords);
  }

  @override
  Widget build(BuildContext context) {
    // valueOrNull keeps the previous trip through the cache re-read that
    // follows every detail view (record() mints a fresh RecentTrip), so a
    // resolved band never collapses and re-grows on the way back.
    final trip =
        ref.watch(cachedTripDetailProvider(widget.tripId)).valueOrNull;
    if (trip == null) return const SizedBox.shrink();
    _recompute(trip, context.l10n);
    if (!_mappable) return const SizedBox.shrink();
    return ClipRRect(
      // Tiles paint square corners; clip to the card's top radius (the
      // bottom edge sits mid-card above the title row).
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
      child: SizedBox(
        height: widget.height,
        child: ExcludeSemantics(
          // Decorative band: keep pin tooltips and the (tap-dead) attribution
          // button out of the a11y tree. AbsorbPointer swallows descendant
          // taps but not the ancestor InkWell, so the whole card stays one
          // tap target — the trip-detail phone preview's mechanism.
          child: AbsorbPointer(
            child: TripMap(
              items: trip.items ?? const [],
              accommodations: _stays,
              // ≥2 destinations → overview pins + route line; fewer (single-
              // city trips) falls back to per-item pins inside TripMap, the
              // same as the detail screen's All view.
              destinations: _destinations,
              interactive: false,
            ),
          ),
        ),
      ),
    );
  }
}
