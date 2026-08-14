// Presentation order for the trips list. The server returns trips
// newest-created-first (its one job is "latest version per chat lineage");
// ordering by travel dates and tucking finished trips away is a display
// concern, so it lives client-side — no SQL change, and the offline cache
// keeps round-tripping the server order verbatim.

import '../models/trip.dart';
import 'trip_days.dart';

/// Splits [trips] into the main list and the "Past trips" group, each ordered
/// for display:
///
/// - `upcoming`: dated, not-past trips soonest first (the next trip you'll
///   actually take on top), then undated trips newest-created first — dated
///   plans are actionable, undated drafts wait below them.
/// - `past`: most recently finished first.
///
/// The trip identified by [liveTripId] (the Happening-Now spotlight) always
/// stays in the main list, so a Live-pill card can never end up filed under
/// past — [tripIsPast] and the live-trip rules disagree about end-less trips.
({List<Trip> upcoming, List<Trip> past}) partitionTripsForList(
  List<Trip> trips,
  DateTime today, {
  String? liveTripId,
}) {
  final dated = <Trip>[];
  final undated = <Trip>[];
  final past = <Trip>[];
  for (final t in trips) {
    if (t.id != liveTripId && tripIsPast(t.startDate, t.endDate, today)) {
      past.add(t);
    } else if (_firstDay(t) != null) {
      dated.add(t);
    } else {
      undated.add(t);
    }
  }
  // List.sort is unstable, so every comparator ends in the createdAt
  // tie-break to keep equal-date trips in a deterministic newest-first order.
  // createdAt is an ISO-8601 string off the wire; lexicographic order is
  // chronological order for it.
  dated.sort((a, b) {
    final c = _firstDay(a)!.compareTo(_firstDay(b)!);
    return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
  });
  undated.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  past.sort((a, b) {
    final c = _lastDay(b)!.compareTo(_lastDay(a)!);
    return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
  });
  return (upcoming: [...dated, ...undated], past: past);
}

/// The trip the "Up next" hero promotes: the first (soonest) trip of a
/// [partitionTripsForList] `upcoming` group, when its START date parses and
/// is today or later. Null when the soonest trip is undated (dated trips
/// sort first, so an undated head means no dated upcoming exist), has
/// already started (an in-progress trip belongs to the live-trip spotlight,
/// and the caller suppresses the hero entirely while one exists), or is
/// end-date-only ([_firstDay]'s endDate fallback sorts it, but a hero with
/// no countdown and no range would show LESS than the plain card it
/// replaces — the start requirement keeps "promoted" a strict upgrade).
Trip? upNextTrip(List<Trip> upcoming, DateTime today) {
  if (upcoming.isEmpty) return null;
  // Started-or-not via the countdown helper, so the hero and its pill can
  // never disagree: promoted ⇔ daysUntilTrip is non-null.
  return daysUntilTrip(upcoming.first.startDate, today) == null
      ? null
      : upcoming.first;
}

/// Sort key for upcoming trips; null means the trip is undated. Falls back to
/// [Trip.endDate] so an end-only trip still sorts by date instead of dropping
/// into the drafts bucket.
DateTime? _firstDay(Trip t) =>
    DateTime.tryParse(t.startDate ?? '') ?? DateTime.tryParse(t.endDate ?? '');

/// Sort key for past trips: the last day, mirroring [tripIsPast]. Non-null for
/// every trip [tripIsPast] classified as past.
DateTime? _lastDay(Trip t) =>
    DateTime.tryParse(t.endDate ?? '') ?? DateTime.tryParse(t.startDate ?? '');
