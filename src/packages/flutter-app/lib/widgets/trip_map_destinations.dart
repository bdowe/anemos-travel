// Destination-pin construction for the trip-overview map, extracted verbatim
// from TripDerivation.compute so the trip-detail derivation and the home
// screen's recent-trip map band share ONE construction site (docs/zen.md:
// derived state is computed in exactly one place). Lives in widgets/ because
// it returns [TripMapDestination] and takes localizations — the utils
// date-derivation files (leg_ranges.dart and friends) stay pure by doctrine:
// no widget/l10n imports, they have Go twins.

import 'package:latlong2/latlong.dart' show LatLng;

import '../l10n/l10n.dart';
import '../utils/date_formats.dart' show formatShortRange, mmmd;
import '../utils/leg_ranges.dart';
import '../utils/trip_legs.dart';
import 'trip_map.dart';

/// Display text for a city-group label: the canonical [kOtherPlacesLabel] key
/// gets a translated label, every real city keeps the name as-is.
String groupLabelText(AppLocalizations l10n, String label) =>
    label == kOtherPlacesLabel ? l10n.tripOtherPlaces : label;

/// Chip entries for a map destination strip: one per leg in visit order,
/// labels display-ready via [groupLabelText]. The ONE construction site for
/// the strip's text — trip detail, the full-screen map (which inherits the
/// detail derivation's list), and the shared view all speak this.
///
/// A trip that revisits a city yields two runs with the SAME label (Fira →
/// Naxos → Fira), and two identical chips are two identical promises: nothing
/// on screen says which stay a tap will focus. Repeated labels therefore carry
/// a [qualifier] — and ONLY repeated ones, so the ordinary trip keeps bare
/// city names and the strip stays narrow on a phone.
///
/// The qualifier is the leg's start date, read from [visibleRanges] — the
/// dates the page RENDERS, never the raw ranges (leg_ranges.dart doctrine:
/// anything promising something about the dates on screen derives from the
/// dates on screen). It degrades to the visit number when dates cannot tell
/// the runs apart, which is not a per-chip special case but one of two whole-
/// strip modes: an undated trip has null ranges for EVERY leg (the allocation
/// is all-or-nothing off `trip.startDate`), and a dense itinerary can collapse
/// two runs onto the same day.
///
/// [qualifier] is kept OUT of [label] deliberately: the label is the city, and
/// callers that speak it in a sentence — `tripNoPlacesInLeg` renders "No
/// places pinned in Fira" — must not inherit "Fira · Sep 3".
///
/// [labelText] overrides how the [kOtherPlacesLabel] run is named. It exists
/// for the shared view, which calls that run "Places" in its own section
/// headers; defaulting it to [groupLabelText] there would have the chip say
/// "Other places" directly above a header saying "Places".
List<({String key, String label, String? qualifier})> mapLegChipEntries(
  AppLocalizations l10n,
  List<TripLeg> legs,
  List<LegRange> visibleRanges, {
  String Function(AppLocalizations, String)? labelText,
}) {
  assert(visibleRanges.length == legs.length,
      'visibleRanges must be index-aligned with legs (both follow tripLegs order)');
  final nameOf = labelText ?? groupLabelText;
  final labels = [for (final leg in legs) nameOf(l10n, leg.label)];

  // Visit-order positions of every label that occurs more than once.
  final repeats = <String, List<int>>{};
  for (var i = 0; i < labels.length; i++) {
    repeats.putIfAbsent(labels[i], () => []).add(i);
  }
  repeats.removeWhere((_, positions) => positions.length < 2);

  final qualifiers = <int, String>{};
  for (final positions in repeats.values) {
    final dates = [
      for (final i in positions)
        visibleRanges[i].start == null
            ? null
            : mmmd().format(visibleRanges[i].start!),
    ];
    // Only useful if every run has a date AND no two share one.
    final datesDistinguish =
        !dates.contains(null) && dates.toSet().length == positions.length;
    for (var n = 0; n < positions.length; n++) {
      qualifiers[positions[n]] =
          datesDistinguish ? dates[n]! : l10n.mapLegVisitNumber(n + 1);
    }
  }

  return [
    for (var i = 0; i < legs.length; i++)
      (key: legs[i].key, label: labels[i], qualifier: qualifiers[i]),
  ];
}

/// Destination pins for the trip-overview map: one per location group with a
/// real coordinate, in visit order; ungeocoded groups are skipped so the
/// visible numbering stays contiguous. Callers pass [rawLegRanges] output —
/// map pins stay on the RAW ranges by doctrine (see leg_ranges.dart).
///
/// [legKeys] (optional) makes the pins navigable: index-aligned with
/// [rawRanges] — both follow tripLegs order, which is why the zip happens
/// BEFORE the coord filter. [LegRange] itself stays key-free by doctrine
/// (record typedef with a Go twin); the key comes from [TripLeg.key].
List<TripMapDestination> tripMapDestinations(
    List<LegRange> rawRanges, AppLocalizations l10n,
    {List<String>? legKeys}) {
  assert(legKeys == null || legKeys.length == rawRanges.length,
      'legKeys must be index-aligned with rawRanges (both follow tripLegs order)');
  return [
    for (final (i, r) in rawRanges.indexed)
      if (r.coord != null)
        TripMapDestination(
          label: groupLabelText(l10n, r.label),
          point: LatLng(r.coord!.lat, r.coord!.lng),
          dates: r.start != null && r.end != null
              ? formatShortRange(r.start!, r.end!)
              : null,
          legKey: legKeys?[i],
        ),
  ];
}
