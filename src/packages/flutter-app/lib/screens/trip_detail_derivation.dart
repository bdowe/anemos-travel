// The trip-detail screen's derivation pipeline, computed ONCE per input
// signature (specs/perf-program, Wave 4 PR1).
//
// Before this file, every setState on the 6000-line hub screen re-ran the
// whole pipeline inside build() — the tripLegs split ~5-6× and the filtered
// list ~4× per build — on view-only taps (row select, city expand, day
// collapse, filter, Today chip, map day chips, pin tap, booked checkbox,
// section toggles). [TripDerivation] absorbs those method bodies verbatim and
// the State memoizes one instance behind `_derive(trip)`:
//
//   * [TripDerivation.compute] is THE one computation site.
//   * [TripDerivation.matches] is the memo signature: `identical()` on the
//     object inputs (trip, bookingTodos, stays, segments, travelByPos, l10n)
//     plus `==` on itemFilter and the item-order epoch. Identity works as an
//     invalidation signal because every mutation path on the screen replaces
//     its input objects wholesale — EXCEPT `_reorderBatchInline`, the one
//     in-place mutation, which bumps the epoch instead (the stated contract:
//     any in-place mutation of a derivation input MUST bump the epoch).
//   * The lazy accessors ([legFilteredItems], [legFilteredStays],
//     [staysOnNight]) return a stable List identity per (derivation, key) —
//     the map-isolation follow-up (Wave 4 PR2) keys its marker cache on that
//     identity, so keep it stable.
//
// The class is immutable in the docs/zen.md sense: all derived state is
// computed from the constructor inputs and nothing here reads the widget
// tree, providers, or the clock. Time-dependent decisions (today's day, the
// Tonight caption gate) stay in build and query this object
// ([firstGroupKeyForDay], [staysOnNight]).

import 'package:latlong2/latlong.dart' show LatLng;

import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/booking_todo.dart';
import '../models/itinerary_item.dart';
import '../models/location_timing.dart';
import '../models/trip.dart';
import '../models/trip_segment.dart';
import '../utils/date_formats.dart';
import '../utils/leg_ranges.dart';
import '../utils/trip_days.dart';
import '../utils/trip_legs.dart';
import '../widgets/trip_map.dart';
import '../widgets/trip_map_destinations.dart';

// [groupLabelText] moved next to the map widget (trip_map_destinations.dart)
// so the home screen's recent-trip map band shares it; re-exported here for
// this file's existing consumers (the trip-detail screen).
export '../widgets/trip_map_destinations.dart' show groupLabelText;

/// City-header date-chip parts, kept separate so the header can align them as
/// columns across rows: [range] renders left-aligned after the calendar icon,
/// [nights] (the localized "· N nights" suffix) renders flush right. Null
/// [nights] = zero-night squeezed leg — no nights widget renders at all.
typedef LegDateChip = ({String range, String? nights});

/// One city group as built by [TripDerivation.compute] and consumed by the
/// screen's `_cityHeader` / group slivers.
typedef CityGroup = ({
  String key,
  String label,
  LegDateChip? dateRange,
  List<ItineraryItem> items
});

/// One city's embedded booking rows: the flight that arrives at the city, its
/// stay, and (for the last city) the return flight home — each todo paired
/// with its matched confirmed record.
typedef BookingSlot = ({
  BookingTodo? arrival,
  TripSegment? arrivalMatch,
  BookingTodo? stay,
  Accommodation? stayMatch,
  BookingTodo? departure,
  TripSegment? departureMatch,
});

/// The one full-label booking partition (see [TripDerivation.groupedBookings]).
typedef GroupedBookings = ({
  List<BookingSlot> slots,
  List<BookingTodo> residual,
  List<Accommodation> residualStays,
  List<TripSegment> residualSegments,
});

/// True for the AI's "city filler" placeholder — an item whose name is just
/// the city it renders under (e.g. name 'Prague', city 'Prague'), emitted for
/// days with no specific activities. Its text duplicates the city/day-trip
/// header it sits below, so hiding the tile is lossless. The SUPPRESSION
/// itself stays in the screen's `_buildGroupItemSlivers` — an all-filler city
/// must keep its group (city header + embedded booking rows).
bool isCityFiller(ItineraryItem item) {
  final name = item.name.trim().toLowerCase();
  if (name.isEmpty) return false;
  bool eq(String? s) => s != null && s.trim().toLowerCase() == name;
  return eq(cityOf(item)) || eq(item.dayTripFrom);
}

/// Formats a travel duration: "45 min", "1h", or "1h 20m".
String fmtTravel(AppLocalizations l10n, int min) {
  if (min < 60) return l10n.tripTravelMinutes(min);
  final h = min ~/ 60;
  final m = min % 60;
  return m == 0 ? l10n.tripTravelHours(h) : l10n.tripTravelHoursMinutes(h, m);
}

class TripDerivation {
  // ── Signature inputs (see [matches]) ──────────────────────────────────
  final Trip trip;
  final List<BookingTodo> bookingTodos;
  final List<Accommodation> stays;
  final List<TripSegment> segments;
  final Map<int, LocationTiming> travelByPos;
  final String itemFilter;

  /// The derivation OUTPUT is localized (nights suffixes, travel labels,
  /// 'Other places'), so the localizations object is a signature input: a
  /// locale switch delivers a new instance and forces a recompute.
  final AppLocalizations l10n;

  /// See the header comment: bumped by the screen for any in-place mutation
  /// of a derivation input, because identity checks can't see those.
  final int itemOrderEpoch;

  // ── Derived state, computed once in [compute] ─────────────────────────

  /// Itinerary items matching the active places lens, used by both the map
  /// and the list so they stay in sync. 'unbooked' and 'bookings' are
  /// bookings lenses, not places ones — the list swaps to booking rows while
  /// the places set (and thus the maps) stays whole.
  final List<ItineraryItem> filtered;

  /// The canonical locality runs over the FULL itinerary (shared [tripLegs]
  /// split) — what the map pin-tap and expand-new-items flows walk.
  final List<TripLeg> legs;

  /// The leg date ranges, raw and as rendered. Both live HERE so every
  /// consumer — header chips, nights suffixes, stay/leg booking todos,
  /// what-to-wear rows — structurally reads the same pair (docs/zen.md: one
  /// derivation, N call sites).
  final List<LegRange> rawRanges;
  final List<LegRange> visibleRanges;

  /// Leg labels in trip order ([rawRanges] order) — the booking-slot keys.
  final List<String> legLabels;

  /// Date window per city-group label (label-keyed, last-wins for revisited
  /// cities), for the embedded weather/events lookups.
  final Map<String, ({DateTime? start, DateTime? end})> groupRanges;

  /// Each itinerary item's position mapped to its location's date-chip parts
  /// (arrival-adjusted [visibleRanges] + localized nights suffix).
  final Map<int, LegDateChip> locationDates;

  /// Consecutive same-locality runs of [filtered], labelled with the date
  /// range precomputed for that location.
  final List<CityGroup> groups;

  /// The one full-label booking partition: todos AND confirmed stays/segments
  /// claimed at most once into per-city slots, plus the residual lists.
  /// Consumers filter this OUTPUT (never re-partition on a label subset — the
  /// claim-once matching is order-dependent, docs/zen.md).
  final GroupedBookings groupedBookings;

  /// Travel-time labels for the trip map, keyed by the source item's
  /// position. Empty while a category filter is active.
  final Map<int, String> segmentLabels;

  /// Destination pins for the trip-overview map, derived from the FULL
  /// itinerary — never the filtered view, which would shift the numbering.
  final List<TripMapDestination> mapDestinations;

  /// The trip's first/last location-group coordinates — the same derivation
  /// the outbound/return booking todos trust.
  final ({LatLng? first, LatLng? last}) homeLegEndpoints;

  /// Map-visibility gate: a filtered item with coordinates OR a geocoded
  /// stay. Shared by build and the pinned-chrome scroll math.
  final bool mapShown;

  /// The trip's user-confirmed stays (auto=false). Suggested drafts are
  /// working state for the bookings hub only — never the map, the Tonight
  /// caption, or the leg ranges.
  final List<Accommodation> confirmedStays;

  /// Day keys (`'$groupKey#$day'`) of the CURRENT groups, collapsed ones
  /// included, so day-jump resolution can expand a group that has never
  /// rendered and still land (specs/today-mode).
  final Set<String> liveDayKeys;

  /// Chip entries for the map's destination strip (specs/map-city-focus):
  /// one per FULL-itinerary leg in visit order, labels display-ready
  /// ([groupLabelText] localizes the 'Other places' run). The strip renders
  /// only with ≥2 entries — with fewer, destination-overview mode never
  /// engages and "All" vs "the one leg" would draw the identical map.
  final List<({String key, String label})> legChips;

  /// Legs that would plot something on the map — the muted-chip gate,
  /// trip-wide (never lens-dependent): a geocoded item in the run, or a
  /// confirmed geocoded stay covering one of the leg's raw-range nights.
  final Set<String> mappedLegKeys;

  // Lazy per-night/per-leg caches — see the header comment for the identity
  // contract.
  final Map<int, List<Accommodation>> _staysOnNightCache = {};
  final Map<String?, List<ItineraryItem>> _legItemsCache = {};
  final Map<String, List<Accommodation>> _legStaysCache = {};

  TripDerivation._({
    required this.trip,
    required this.bookingTodos,
    required this.stays,
    required this.segments,
    required this.travelByPos,
    required this.itemFilter,
    required this.l10n,
    required this.itemOrderEpoch,
    required this.filtered,
    required this.legs,
    required this.rawRanges,
    required this.visibleRanges,
    required this.legLabels,
    required this.groupRanges,
    required this.locationDates,
    required this.groups,
    required this.groupedBookings,
    required this.segmentLabels,
    required this.mapDestinations,
    required this.homeLegEndpoints,
    required this.mapShown,
    required this.confirmedStays,
    required this.liveDayKeys,
    required this.legChips,
    required this.mappedLegKeys,
  });

  /// Whether this derivation is still valid for the given inputs: identity
  /// on the object inputs, equality on the filter and the epoch. Every
  /// mutation path on the screen replaces its input objects wholesale, so a
  /// surviving identity means unchanged content (the epoch covers the one
  /// documented in-place exception).
  bool matches({
    required Trip trip,
    required List<BookingTodo> bookingTodos,
    required List<Accommodation> stays,
    required List<TripSegment> segments,
    required Map<int, LocationTiming> travelByPos,
    required String itemFilter,
    required AppLocalizations l10n,
    required int itemOrderEpoch,
  }) =>
      identical(trip, this.trip) &&
      identical(bookingTodos, this.bookingTodos) &&
      identical(stays, this.stays) &&
      identical(segments, this.segments) &&
      identical(travelByPos, this.travelByPos) &&
      identical(l10n, this.l10n) &&
      itemFilter == this.itemFilter &&
      itemOrderEpoch == this.itemOrderEpoch;

  /// Stays covering the night of trip day [day], checkout-exclusively — the
  /// single home of the day→night math shared by the map's day filter and
  /// the Tonight caption. A trip without a parseable start date can't map
  /// Day N to a calendar date, so no stay matches. Stable List identity per
  /// (derivation, day).
  List<Accommodation> staysOnNight(int day) =>
      _staysOnNightCache.putIfAbsent(day, () {
        final start = DateTime.tryParse(trip.startDate ?? '');
        if (start == null) return const [];
        // Calendar-day arithmetic (constructor normalizes overflow) rather
        // than Duration, which drifts a date across a DST transition.
        final night = DateTime(start.year, start.month, start.day + day - 1);
        return confirmedStays
            .where((a) => stayCoversDate(a.checkIn, a.checkOut, night))
            .toList();
      });

  /// The FIRST group (build order) containing an item on trip day [day], or
  /// null. Feeds the Tonight-caption seeding: day numbers repeat across city
  /// groups, so exactly one group may ever show the caption. Matched on the
  /// run key, not the label: a revisited city has two runs sharing a label.
  String? firstGroupKeyForDay(int? day) {
    if (day == null) return null;
    for (final group in groups) {
      if (group.items.any((it) => it.day == day)) return group.key;
    }
    return null;
  }

  /// [filtered] narrowed to a focused leg (null = All → [filtered] itself).
  /// Membership is the item's POSITION against the FULL-itinerary leg: a
  /// places lens can merge adjacent runs and shift group keys, but positions
  /// are stable, so lens ∩ leg composes correctly. Unknown key → empty.
  /// Stable List identity per (derivation, key).
  List<ItineraryItem> legFilteredItems(String? legKey) =>
      _legItemsCache.putIfAbsent(legKey, () {
        if (legKey == null) return filtered;
        final i = legIndexOf(legKey);
        if (i == null) return const [];
        final positions = {for (final it in legs[i].items) it.position};
        return filtered
            .where((it) => positions.contains(it.position))
            .toList();
      });

  /// Stays the map should plot for a focused leg: under All (null), every
  /// confirmed stay; under a leg, confirmed stays covering one of the leg's
  /// raw-range nights ([rawRanges] is index-aligned with [legs] — both run
  /// the same tripLegs split). Checkout-exclusive on both sides, so a
  /// zero-night squeezed leg and an undated leg plot none. Stable List
  /// identity per (derivation, key).
  List<Accommodation> legFilteredStays(String? legKey) {
    if (legKey == null) return confirmedStays;
    return _legStaysCache.putIfAbsent(legKey, () {
      final i = legIndexOf(legKey);
      if (i == null) return const [];
      final start = rawRanges[i].start;
      final end = rawRanges[i].end;
      if (start == null || end == null) return const [];
      return confirmedStays
          .where((a) => stayCoversAnyNight(a.checkIn, a.checkOut, start, end))
          .toList();
    });
  }

  /// The FIRST full-itinerary leg (visit order) with an item tagged trip day
  /// [day], or null — the Today-mode focus resolver. Leg twin of
  /// [firstGroupKeyForDay], which stays on GROUP keys for the Tonight
  /// caption.
  String? legKeyForDay(int? day) {
    if (day == null) return null;
    for (final leg in legs) {
      if (leg.items.any((it) => it.day == day)) return leg.key;
    }
    return null;
  }

  /// The full-itinerary leg containing the item at [position], or null.
  String? legKeyOfPosition(int position) {
    for (final leg in legs) {
      if (leg.items.any((it) => it.position == position)) return leg.key;
    }
    return null;
  }

  /// Index of [legKey] in [legs] (and thus [rawRanges]) order, or null.
  int? legIndexOf(String legKey) {
    for (var i = 0; i < legs.length; i++) {
      if (legs[i].key == legKey) return i;
    }
    return null;
  }

  /// The CURRENT-filter group holding [legKey]'s items: the leg key itself
  /// under the full itinerary, possibly a merged run's key under a places
  /// lens, or null when the key is stale or the lens dropped every item of
  /// the leg (nothing should render open — its items aren't in the list).
  /// Positions-based like [legFilteredItems]: lenses only MERGE adjacent
  /// runs, never split one, so leg → group is a function. This is the one
  /// leg→group mapping (specs/map-city-focus accordion) — expansion is
  /// derived through it at read time, and it clamps, so build never needs
  /// to write focus state. Null in → null out, matching a no-focus screen.
  String? groupKeyForLeg(String? legKey) {
    if (legKey == null) return null;
    final i = legIndexOf(legKey);
    if (i == null) return null;
    final positions = {for (final it in legs[i].items) it.position};
    for (final group in groups) {
      if (group.items.any((it) => positions.contains(it.position))) {
        return group.key;
      }
    }
    return null;
  }

  /// Day preselect for adding a place to a focused leg: the smallest day tag
  /// among the leg's items, else the leg's raw start offset from the trip
  /// start (clamped to day 1), else null — no preselection, matching the
  /// null-[legKey] (All) behavior.
  int? dayForLeg(String? legKey) {
    if (legKey == null) return null;
    final i = legIndexOf(legKey);
    if (i == null) return null;
    int? minDay;
    for (final it in legs[i].items) {
      final d = it.day;
      if (d != null && d >= 1 && (minDay == null || d < minDay)) minDay = d;
    }
    if (minDay != null) return minDay;
    final start = rawRanges[i].start;
    final tripStart = DateTime.tryParse(trip.startDate ?? '');
    if (start == null || tripStart == null) return null;
    // UTC-normalized like [nightsBetween] so DST can't skew the offset.
    final diff = DateTime.utc(start.year, start.month, start.day)
        .difference(
            DateTime.utc(tripStart.year, tripStart.month, tripStart.day))
        .inDays;
    return diff < 0 ? 1 : diff + 1;
  }

  /// THE one computation site for everything above. Bodies are verbatim from
  /// the screen's former per-build methods; see each field's doc.
  static TripDerivation compute({
    required Trip trip,
    required List<BookingTodo> bookingTodos,
    required List<Accommodation> stays,
    required List<TripSegment> segments,
    required Map<int, LocationTiming> travelByPos,
    required String itemFilter,
    required AppLocalizations l10n,
    required int itemOrderEpoch,
  }) {
    final items = trip.items ?? const <ItineraryItem>[];

    final filtered = switch (itemFilter) {
      // The bookings lenses and the Budget view keep the item set whole —
      // the map, leg chips, and Today math stay itinerary-shaped there.
      'all' || 'unbooked' || 'bookings' || 'budget' => items.toList(),
      'local' => items
          .where((i) => (i.localSourceName ?? '').trim().isNotEmpty)
          .toList(),
      _ => items.where((i) => i.category == itemFilter).toList(),
    };

    final confirmedStays = (trip.accommodations ?? const <Accommodation>[])
        .where((a) => !a.auto)
        .toList();

    final legs = tripLegs(items);
    final rawRanges = rawLegRanges(trip);
    final visibleRanges = visibleLegRanges(trip);
    final legLabels = [for (final r in rawRanges) r.label];
    final groupRanges = {
      for (final r in rawRanges) r.label: (start: r.start, end: r.end)
    };

    // Per-position date chips from the arrival-adjusted visible ranges —
    // index-aligned with [legs] by construction (both run the same tripLegs
    // split over the same items). Both strings are final display text: the
    // chip-width measurement must see these exact strings, never
    // re-formatted copies.
    final locationDates = <int, LegDateChip>{};
    for (var gi = 0; gi < legs.length; gi++) {
      final start = visibleRanges[gi].start;
      final end = visibleRanges[gi].end;
      if (start == null || end == null) continue;
      final nights = nightsBetween(start, end);
      final chip = (
        range: formatShortRange(start, end),
        nights: nights > 0 ? l10n.tripLegNights(nights) : null,
      );
      for (final item in legs[gi].items) {
        locationDates[item.position] = chip;
      }
    }

    // Groups run the split over the FILTERED items (a category filter can
    // merge adjacent same-label runs); chips key by first item position into
    // the full-itinerary map above.
    final groups = <CityGroup>[
      for (final leg in tripLegs(filtered))
        (
          key: leg.key,
          label: leg.label,
          dateRange: locationDates[leg.items.first.position],
          items: leg.items,
        ),
    ];

    final groupedBookings = _computeGroupedBookings(
        legLabels, bookingTodos, stays, segments);

    // Travel-time labels for the map: one entry per within-city leg (same
    // hub, adjacent in itinerary order). Empty while a category filter is
    // active (legs aren't globally adjacent).
    final segmentLabels = <int, String>{};
    if (itemFilter == 'all') {
      final byPos = {for (final it in items) it.position: it};
      for (final it in items) {
        final next = byPos[it.position + 1];
        if (next == null || hubOf(it) != hubOf(next)) continue;
        final t = travelByPos[it.position];
        if (t == null || t.travelToNextMin <= 0) continue;
        segmentLabels[it.position] = fmtTravel(l10n, t.travelToNextMin);
      }
    }

    // Destination pins: the one construction site lives with the map widget
    // (trip_map_destinations.dart), shared with the home recent-trip band.
    final mapDestinations = tripMapDestinations(rawRanges, l10n);

    final firstCoord = rawRanges.isEmpty ? null : rawRanges.first.coord;
    final lastCoord = rawRanges.isEmpty ? null : rawRanges.last.coord;
    final homeLegEndpoints = (
      first:
          firstCoord == null ? null : LatLng(firstCoord.lat, firstCoord.lng),
      last: lastCoord == null ? null : LatLng(lastCoord.lat, lastCoord.lng),
    );

    final mapShown =
        filtered.any((i) => i.latitude != 0 || i.longitude != 0) ||
            confirmedStays.any(TripMap.stayHasCoords);

    // Mirrors the screen's `_buildGroupItemSlivers` day-header rule:
    // non-filler items carrying a day tag.
    final liveDayKeys = <String>{
      for (final g in groups)
        for (final it in g.items)
          if (!isCityFiller(it) && it.day != null) '${g.key}#${it.day}',
    };

    final legChips = <({String key, String label})>[
      for (final leg in legs)
        (key: leg.key, label: groupLabelText(l10n, leg.label)),
    ];

    final geoStays = [
      for (final a in confirmedStays)
        if (TripMap.stayHasCoords(a)) a,
    ];
    final mappedLegKeys = <String>{};
    for (var i = 0; i < legs.length; i++) {
      if (legs[i].coord != null) {
        mappedLegKeys.add(legs[i].key);
        continue;
      }
      final start = rawRanges[i].start;
      final end = rawRanges[i].end;
      if (start == null || end == null) continue;
      if (geoStays
          .any((a) => stayCoversAnyNight(a.checkIn, a.checkOut, start, end))) {
        mappedLegKeys.add(legs[i].key);
      }
    }

    return TripDerivation._(
      trip: trip,
      bookingTodos: bookingTodos,
      stays: stays,
      segments: segments,
      travelByPos: travelByPos,
      itemFilter: itemFilter,
      l10n: l10n,
      itemOrderEpoch: itemOrderEpoch,
      filtered: filtered,
      legs: legs,
      rawRanges: rawRanges,
      visibleRanges: visibleRanges,
      legLabels: legLabels,
      groupRanges: groupRanges,
      locationDates: locationDates,
      groups: groups,
      groupedBookings: groupedBookings,
      segmentLabels: segmentLabels,
      mapDestinations: mapDestinations,
      homeLegEndpoints: homeLegEndpoints,
      mapShown: mapShown,
      confirmedStays: confirmedStays,
      liveDayKeys: liveDayKeys,
      legChips: legChips,
      mappedLegKeys: mappedLegKeys,
    );
  }

  /// Partitions the booking todos AND the confirmed stays/segments into
  /// per-city embedded slots — the flight that arrives at the city, its stay,
  /// and (for the last city) the return flight home — plus the residual lists
  /// of everything that matched no city (user-added `custom:*` todos, stale
  /// auto todos, confirmed records for legs no longer in the trip). Each todo
  /// and record is claimed at most once, so repeated city labels still render
  /// each booking exactly once.
  ///
  /// Confirmed records match their slot by the shared key grammar first
  /// (`stay:<city>` / `transport:<a>>><b>` on auto_key, stamped when a draft
  /// was confirmed) and fall back to the same fuzzy rules the old drafts
  /// derivation used: stays by bidirectional name/address contains of the
  /// city label, segments by destination (arrivals) or origin (departure)
  /// equality — mirroring how the todo keys themselves are claimed.
  static GroupedBookings _computeGroupedBookings(
    List<String> groupLabels,
    List<BookingTodo> bookingTodos,
    List<Accommodation> stays,
    List<TripSegment> segments,
  ) {
    final claimed = <String>{};
    BookingTodo? claim(bool Function(BookingTodo) test) {
      for (final t in bookingTodos) {
        if (!claimed.contains(t.id) && test(t)) {
          claimed.add(t.id);
          return t;
        }
      }
      return null;
    }

    final confirmedStays = stays.where((a) => !a.auto).toList();
    final confirmedSegments = segments.where((s) => !s.auto).toList();
    final claimedStayIds = <String>{};
    final claimedSegmentIds = <String>{};
    Accommodation? claimStay(bool Function(Accommodation) test) {
      for (final a in confirmedStays) {
        if (!claimedStayIds.contains(a.id) && test(a)) {
          claimedStayIds.add(a.id);
          return a;
        }
      }
      return null;
    }

    TripSegment? claimSegment(bool Function(TripSegment) test) {
      for (final s in confirmedSegments) {
        if (!claimedSegmentIds.contains(s.id) && test(s)) {
          claimedSegmentIds.add(s.id);
          return s;
        }
      }
      return null;
    }

    final arrivals = <BookingTodo?>[];
    final arrivalMatches = <TripSegment?>[];
    final staySlots = <BookingTodo?>[];
    final stayMatches = <Accommodation?>[];
    for (final label in groupLabels) {
      final l = label.toLowerCase();
      arrivals.add(
          claim((t) => t.kind == 'transport' && t.todoKey.endsWith('>>$l')));
      arrivalMatches.add(claimSegment((s) =>
          (s.autoKey?.endsWith('>>$l') ?? false) ||
          s.destination?.toLowerCase() == l));
      staySlots.add(claim((t) => t.todoKey == 'stay:$l'));
      stayMatches.add(claimStay((a) {
        if (a.autoKey == 'stay:$l') return true;
        for (final field in [a.name, a.address]) {
          final f = field?.toLowerCase();
          if (f != null && f.isNotEmpty && (f.contains(l) || l.contains(f))) {
            return true;
          }
        }
        return false;
      }));
    }
    // Claimed after all arrivals so an inter-city leg can't be taken as its
    // origin's departure — only the final leg home remains unclaimed by then.
    BookingTodo? departure;
    TripSegment? departureMatch;
    if (groupLabels.isNotEmpty) {
      final last = groupLabels.last.toLowerCase();
      departure = claim((t) =>
          t.kind == 'transport' && t.todoKey.startsWith('transport:$last>>'));
      departureMatch = claimSegment((s) =>
          (s.autoKey?.startsWith('transport:$last>>') ?? false) ||
          s.origin?.toLowerCase() == last);
    }

    return (
      slots: [
        for (var i = 0; i < groupLabels.length; i++)
          (
            arrival: arrivals[i],
            arrivalMatch: arrivalMatches[i],
            stay: staySlots[i],
            stayMatch: stayMatches[i],
            departure: i == groupLabels.length - 1 ? departure : null,
            departureMatch:
                i == groupLabels.length - 1 ? departureMatch : null,
          ),
      ],
      residual: bookingTodos.where((t) => !claimed.contains(t.id)).toList(),
      residualStays: confirmedStays
          .where((a) => !claimedStayIds.contains(a.id))
          .toList(),
      residualSegments: confirmedSegments
          .where((s) => !claimedSegmentIds.contains(s.id))
          .toList(),
    );
  }
}
