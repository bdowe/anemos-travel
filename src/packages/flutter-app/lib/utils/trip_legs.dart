// The client-side "city legs" derivation: consecutive runs of itinerary items
// sharing a hub locality, in visit (itinerary) order. Shared by the trip
// detail screen (grouping, location date ranges, map destinations), the
// shared trip view, and the trip map so they can never drift apart.
//
// Pure like trip_days.dart: no widget/l10n imports, just the item model.
// The server has a twin of the run split (legRuns in plan_leg_dates.go) whose
// empty-hub rule differs on purpose — see [tripLegs].

import '../models/itinerary_item.dart';

/// Canonical group key/label for items whose locality can't be resolved. It
/// keys the collapse/header registries and gates refine/events/local sections,
/// so it is NEVER translated — screens map it to a localized display label at
/// render time (specs/i18n-spanish).
const String kOtherPlacesLabel = 'Other places';

/// One consecutive run of same-locality itinerary items — a city leg.
///
/// [key] identifies the *run*: a trip that revisits a city (Athens → Fira →
/// Oia → Fira) yields two runs with the same [label], and everything keyed
/// per-run (header GlobalKeys, collapse sets, `key#day` day keys) must tell
/// them apart — repeats get a `#2`, `#3`, … suffix. [locality] is the raw
/// nullable hub for lookups that must not see the [kOtherPlacesLabel]
/// placeholder (e.g. stay-address matching); [label] is `locality` with that
/// placeholder applied. [coord] is a representative coordinate: the first
/// item with real coordinates, null when the whole run is ungeocoded ((0,0)
/// is the "no location" sentinel for manually-added places).
typedef TripLeg = ({
  String key,
  String label,
  String? locality,
  List<ItineraryItem> items,
  ({double lat, double lng})? coord,
});

/// The locality an item groups under: its day-trip hub city when set, else its
/// own city. Day trips (e.g. Versailles) thus fold under the hub (e.g. Paris).
String? hubOf(ItineraryItem item) {
  final h = item.dayTripFrom?.trim();
  if (h != null && h.isNotEmpty) return h;
  return cityOf(item);
}

/// The city an item belongs to: the AI-assigned [ItineraryItem.city] when set,
/// otherwise a best-effort parse of the formatted address.
String? cityOf(ItineraryItem item) {
  final c = item.city?.trim();
  if (c != null && c.isNotEmpty) return c;
  return cityFromAddress(item.address);
}

// Hoisted out of [cityFromAddress]: it runs per item per legs split, and a
// RegExp compile per call was measurable on the trip-detail hot path
// (specs/perf-program, Wave 4 PR1).
final RegExp _whitespaceRe = RegExp(r'\s+');
final RegExp _postalTokenRe = RegExp(r'^[0-9][0-9\-]*$');

/// Fallback city from a formatted address. Drops the country (last segment)
/// and strips postal-code tokens from the segment before it, e.g.
/// "Av. ..., 1400-206 Lisboa, Portugal" -> "Lisboa"; a bare "Paris" stays as is.
String? cityFromAddress(String? address) {
  if (address == null) return null;
  final parts = address
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  if (parts.length == 1) return parts.first;
  final candidate = parts[parts.length - 2]; // segment before the country
  final tokens = candidate
      .split(_whitespaceRe)
      .where((t) => !_postalTokenRe.hasMatch(t)) // drop postal tokens
      .toList();
  final city = tokens.join(' ').trim();
  return city.isEmpty ? candidate : city;
}

/// Splits [items] into consecutive same-locality runs — the trip's city legs
/// in visit order. A null locality starts its own run and groups with adjacent
/// null-locality items (null == null); this is deliberately the client rule,
/// NOT the server's empty-hub-adopts-the-current-run rule (plan_leg_dates.go).
List<TripLeg> tripLegs(List<ItineraryItem> items) {
  final runs = <({String? locality, List<ItineraryItem> items})>[];
  String? currentKey;
  for (final item in items) {
    final locality = hubOf(item);
    if (runs.isEmpty || locality != currentKey) {
      runs.add((locality: locality, items: <ItineraryItem>[]));
      currentKey = locality;
    }
    runs.last.items.add(item);
  }

  final seen = <String, int>{};
  final legs = <TripLeg>[];
  for (final run in runs) {
    final label = run.locality ?? kOtherPlacesLabel;
    final n = (seen[label] ?? 0) + 1;
    seen[label] = n;
    legs.add((
      key: n == 1 ? label : '$label#$n',
      label: label,
      locality: run.locality,
      items: run.items,
      coord: _legCoord(run.items),
    ));
  }
  return legs;
}

/// The first item with real coordinates, as a leg's representative point.
({double lat, double lng})? _legCoord(List<ItineraryItem> items) {
  for (final it in items) {
    if (it.latitude != 0 || it.longitude != 0) {
      return (lat: it.latitude, lng: it.longitude);
    }
  }
  return null;
}
