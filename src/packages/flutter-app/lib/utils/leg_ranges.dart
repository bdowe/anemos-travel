// The client-side leg DATE-RANGE derivation: the calendar span each city leg
// occupies, raw ([rawLegRanges]) and as rendered ([visibleLegRanges]).
// Extracted verbatim from trip_detail_screen.dart (specs/trip-dates-truth,
// stage 0a) so the trip screen, its booking-todo derivation, and the upcoming
// Go twin (trip_render_legs.go) share one testable definition.
//
// Pure like trip_legs.dart / trip_days.dart: no widget/l10n imports. The
// server mirrors [visibleLegRanges] in visibleLegDisplayRange
// (plan_leg_dates.go) today and in the trip_render_legs.go module once the
// legs payload ships — the twin tests hand-mirror this file's fixtures.

import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../models/trip.dart';
import 'trip_legs.dart';

/// One leg's date range. [stayAnchored] marks a range taken from a confirmed
/// accommodation's explicit dates, which exempts the leg from the
/// visible-range zero-night collapse.
typedef LegRange = ({
  String label,
  DateTime? start,
  DateTime? end,
  ({double lat, double lng})? coord,
  bool stayAnchored,
});

/// Per-location-group label and date range. Each location gets a contiguous
/// slice of the trip's start–end span, weighted by how many places it has; an
/// accommodation with its own dates overrides the computed slice (and sets
/// [LegRange.stayAnchored]). Computed over the full itinerary so category
/// filters don't shift the allocation.
List<LegRange> rawLegRanges(Trip trip) {
  final items = trip.items ?? const <ItineraryItem>[];
  if (items.isEmpty) return const [];
  // Confirmed only: a suggested draft's dates come FROM this derivation, so
  // letting them back in via _accDateRangeFor would freeze the ranges. Same
  // !auto rule as the trip screen's _confirmedStays.
  final stays = (trip.accommodations ?? const <Accommodation>[])
      .where((a) => !a.auto)
      .toList();

  // Canonical locality runs over the full itinerary (shared split).
  final legs = tripLegs(items);

  // Auto-split the trip span across groups, weighted by item count.
  final start = DateTime.tryParse(trip.startDate ?? '');
  final end = DateTime.tryParse(trip.endDate ?? '');
  final auto = List<({DateTime start, DateTime end})?>.filled(legs.length, null);
  if (start != null && end != null && !end.isBefore(start)) {
    final totalDays = end.difference(start).inDays + 1;
    final n = legs.length;
    if (n <= totalDays) {
      // Enough days: give each location a contiguous slice weighted by size.
      final counts =
          allocateDays(totalDays, [for (final leg in legs) leg.items.length]);
      var cursor = start;
      for (var i = 0; i < n; i++) {
        final rStart = cursor.isAfter(end) ? end : cursor;
        var rEnd = rStart.add(Duration(days: counts[i] - 1));
        if (rEnd.isAfter(end)) rEnd = end;
        auto[i] = (start: rStart, end: rEnd);
        cursor = rEnd.add(const Duration(days: 1));
      }
    } else {
      // More locations than days: map each to a single day in order, so dates
      // stay ascending and within the trip (some days carry several stops).
      for (var i = 0; i < n; i++) {
        final d = start
            .add(Duration(days: (i * totalDays ~/ n).clamp(0, totalDays - 1)));
        auto[i] = (start: d, end: d);
      }
    }
  }

  final result = <LegRange>[];
  for (var i = 0; i < legs.length; i++) {
    final leg = legs[i];
    // The raw nullable locality feeds the stay-address match — the
    // 'Other places' placeholder label would falsely substring-match.
    final accRange = _accDateRangeFor(leg.locality, stays);
    final dayRange = _dayRangeFor(leg.items, start);
    final a = auto[i];
    var rangeStart = accRange?.start ?? dayRange?.start ?? a?.start;
    // First-leg trip-start anchor: the traveler is in the first city from
    // the trip's first day, so an item-derived range must not start later
    // (a single late item would render a bare "Aug 27" on an Aug 24 trip).
    // A confirmed stay's check-in still wins; the server mirrors this in
    // anchoredLegDisplayRange (plan_leg_dates.go).
    if (i == 0 &&
        accRange == null &&
        start != null &&
        rangeStart != null &&
        start.isBefore(rangeStart)) {
      rangeStart = start;
    }
    result.add((
      label: leg.label,
      start: rangeStart,
      end: accRange?.end ?? dayRange?.end ?? a?.end,
      coord: leg.coord,
      stayAnchored: accRange != null,
    ));
  }
  return result;
}

/// The ranges the page RENDERS: [rawLegRanges] plus the arrival rule, as one
/// forward pass. A leg renders from its arrival — the previous group's
/// VISIBLE end — when that comes first, and COLLAPSES to a zero-night stop at
/// the arrival when the previous leg has run past the leg's own last day (the
/// interim state a set_leg_dates squeeze leaves behind, narrated as "no
/// nights left" in chat). Cascading: each leg clamps against the previous
/// VISIBLE end, so consecutive squeezed legs chain and the inter-city leg
/// dates (previous end) follow automatically. A confirmed stay's explicit
/// dates are never collapsed (same carve-out as the first-leg anchor); an
/// arrival strictly inside a leg's own span keeps the leg's start (partial
/// overlap — unchanged). Stay todos, inter-city leg dates, and header chips
/// consume THIS; map pins and weather/events stay on the raw ranges. The
/// server mirrors this in visibleLegDisplayRange (plan_leg_dates.go).
List<LegRange> visibleLegRanges(Trip trip) {
  final raw = rawLegRanges(trip);
  final result = <LegRange>[];
  DateTime? prevEnd;
  for (final r in raw) {
    var start = r.start;
    var end = r.end;
    if (prevEnd != null) {
      if (start == null || prevEnd.isBefore(start)) {
        start = prevEnd;
      } else if (end != null && prevEnd.isAfter(end) && !r.stayAnchored) {
        start = prevEnd;
        end = prevEnd;
      }
    }
    result.add((
      label: r.label,
      start: start,
      end: end,
      coord: r.coord,
      stayAnchored: r.stayAnchored,
    ));
    prevEnd = end;
  }
  return result;
}

/// Date range for a location group from its items' AI-assigned day numbers,
/// anchored to the trip start: day N -> startDate + (N-1). Null when the trip
/// has no start date or none of the items carry a day.
({DateTime start, DateTime end})? _dayRangeFor(
    List<ItineraryItem> items, DateTime? tripStart) {
  if (tripStart == null) return null;
  int? lo, hi;
  for (final it in items) {
    final d = it.day;
    if (d == null || d < 1) continue;
    if (lo == null || d < lo) lo = d;
    if (hi == null || d > hi) hi = d;
  }
  if (lo == null || hi == null) return null;
  return (
    start: tripStart.add(Duration(days: lo - 1)),
    end: tripStart.add(Duration(days: hi - 1)),
  );
}

/// First accommodation in [locality] with both check-in/out dates, as DateTimes.
({DateTime start, DateTime end})? _accDateRangeFor(
    String? locality, List<Accommodation> stays) {
  if (locality == null) return null;
  final key = locality.toLowerCase();
  for (final acc in stays) {
    final addr = acc.address?.toLowerCase();
    if (addr == null) continue;
    if ((addr.contains(key) || key.contains(addr)) &&
        acc.checkIn != null &&
        acc.checkOut != null) {
      final ci = DateTime.tryParse(acc.checkIn!);
      final co = DateTime.tryParse(acc.checkOut!);
      if (ci != null && co != null) return (start: ci, end: co);
    }
  }
  return null;
}

/// Splits [totalDays] across groups proportional to [weights], each group at
/// least 1 day, summing to totalDays (largest-remainder; trims overflow from
/// the largest groups when the min-1 floor pushes the total over). Public for
/// direct unit tests; [rawLegRanges] is its only production caller.
List<int> allocateDays(int totalDays, List<int> weights) {
  final n = weights.length;
  if (n == 0) return const [];
  if (totalDays <= n) {
    return List.filled(n, 1); // ranges clamp to the trip end
  }
  final totalW = weights.fold<int>(0, (s, w) => s + (w <= 0 ? 1 : w));
  final exact = [
    for (final w in weights) totalDays * (w <= 0 ? 1 : w) / totalW
  ];
  final counts = [for (final e in exact) e.floor() < 1 ? 1 : e.floor()];
  var used = counts.fold<int>(0, (s, c) => s + c);
  // Hand out any remaining days to the largest fractional remainders.
  final byRemainder = List<int>.generate(n, (i) => i)
    ..sort((a, b) =>
        (exact[b] - exact[b].floor()).compareTo(exact[a] - exact[a].floor()));
  for (var k = 0; used < totalDays; k++) {
    counts[byRemainder[k % n]] += 1;
    used++;
  }
  // Or trim back from the largest groups if min-1 overshot.
  final byCount = List<int>.generate(n, (i) => i)
    ..sort((a, b) => counts[b].compareTo(counts[a]));
  for (var k = 0; used > totalDays; k++) {
    final j = byCount[k % n];
    if (counts[j] > 1) {
      counts[j]--;
      used--;
    }
  }
  return counts;
}

/// Whole nights between two local-midnight dates, checkout-exclusive
/// (Aug 24 -> Aug 27 = 3; same day = 0). UTC-normalized so a DST
/// transition inside the range can't skew the count. Client display
/// only — NOT part of the Go-twin contract; the legs payload carries
/// no nights field.
int nightsBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;
