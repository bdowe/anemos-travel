// Destination-pin construction for the trip-overview map, extracted verbatim
// from TripDerivation.compute so the trip-detail derivation and the home
// screen's recent-trip map band share ONE construction site (docs/zen.md:
// derived state is computed in exactly one place). Lives in widgets/ because
// it returns [TripMapDestination] and takes localizations — the utils
// date-derivation files (leg_ranges.dart and friends) stay pure by doctrine:
// no widget/l10n imports, they have Go twins.

import 'package:latlong2/latlong.dart' show LatLng;

import '../l10n/l10n.dart';
import '../utils/date_formats.dart';
import '../utils/leg_ranges.dart';
import '../utils/trip_legs.dart';
import 'trip_map.dart';

/// Display text for a city-group label: the canonical [kOtherPlacesLabel] key
/// gets a translated label, every real city keeps the name as-is.
String groupLabelText(AppLocalizations l10n, String label) =>
    label == kOtherPlacesLabel ? l10n.tripOtherPlaces : label;

/// Destination pins for the trip-overview map: one per location group with a
/// real coordinate, in visit order; ungeocoded groups are skipped so the
/// visible numbering stays contiguous. Callers pass [rawLegRanges] output —
/// map pins stay on the RAW ranges by doctrine (see leg_ranges.dart).
List<TripMapDestination> tripMapDestinations(
        List<LegRange> rawRanges, AppLocalizations l10n) =>
    [
      for (final r in rawRanges)
        if (r.coord != null)
          TripMapDestination(
            label: groupLabelText(l10n, r.label),
            point: LatLng(r.coord!.lat, r.coord!.lng),
            dates: r.start != null && r.end != null
                ? formatShortRange(r.start!, r.end!)
                : null,
          ),
    ];
