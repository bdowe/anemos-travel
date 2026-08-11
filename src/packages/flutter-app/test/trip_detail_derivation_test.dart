// TripDerivation memo + parity tests (specs/perf-program, Wave 4 PR1).
//
// Pure Dart — no widget pumping. Three concerns:
//   1. The memo signature: [TripDerivation.matches] reuses on identical
//      inputs and invalidates on every single input flip (incl. the
//      item-order epoch, the one non-identity signal).
//   2. Identity stability of the lazy per-day accessors — the map-isolation
//      follow-up (Wave 4 PR2) keys a marker cache on those List identities.
//   3. Parity spot-checks of the absorbed pipeline (groups, locationDates,
//      groupedBookings, segmentLabels, day math) against the legacy shapes
//      the screen used to compute inline.

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/app_localizations_en.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/location.dart';
import 'package:travel_route_planner/models/location_timing.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/screens/trip_detail_derivation.dart';

ItineraryItem _item(
  int pos,
  String name, {
  String? city,
  int? day,
  double lat = 0,
  double lng = 0,
  String category = 'attraction',
  String? localSourceName,
}) =>
    ItineraryItem(
      id: 'i-$name',
      position: pos,
      name: name,
      address: '$name address, $city',
      latitude: lat,
      longitude: lng,
      category: category,
      city: city,
      day: day,
      localSourceName: localSourceName,
    );

/// Paris (2 items) → Rome (2 items) → Paris again (1 item): exercises the
/// revisited-city `#2` run key, per-position date chips, and a coordinate-less
/// item.
List<ItineraryItem> _items() => [
      _item(0, 'Louvre', city: 'Paris', day: 1, lat: 48.86, lng: 2.35),
      _item(1, 'Le Comptoir',
          city: 'Paris',
          day: 2,
          lat: 48.85,
          lng: 2.32,
          category: 'restaurant',
          localSourceName: 'Maria'),
      _item(2, 'Colosseum', city: 'Rome', day: 3, lat: 41.89, lng: 12.49),
      _item(3, 'Trevi', city: 'Rome', day: 4),
      _item(4, 'Louvre Again', city: 'Paris', day: 5, lat: 48.86, lng: 2.35),
    ];

Trip _trip({List<ItineraryItem>? items, List<Accommodation>? stays}) => Trip(
      id: 't1',
      title: 'Paris & Rome',
      status: 'planned',
      startDate: '2026-09-01',
      endDate: '2026-09-05',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items ?? _items(),
      accommodations: stays,
    );

const _parisStay = Accommodation(
  id: 'a1',
  name: 'Hotel Paris',
  address: 'Rue X, Paris, France',
  latitude: 48.87,
  longitude: 2.36,
  checkIn: '2026-09-01',
  checkOut: '2026-09-03',
);

const _draftStay = Accommodation(
  id: 'a2',
  name: 'Suggested Rome',
  address: 'Via Y, Rome, Italy',
  auto: true,
);

BookingTodo _todo(String key, {String kind = 'transport', bool booked = false}) =>
    BookingTodo(
      id: 'todo-$key',
      kind: kind,
      todoKey: key,
      title: key,
      booked: booked,
    );

LocationTiming _timing(int minutes) => LocationTiming(
      location: const Location(id: 'x', name: 'x'),
      arrivalTime: '09:00',
      departureTime: '10:00',
      visitDurationMin: 60,
      travelToNextMin: minutes,
    );

TripDerivation _compute({
  Trip? trip,
  List<BookingTodo>? bookingTodos,
  List<Accommodation>? stays,
  List<TripSegment>? segments,
  Map<int, LocationTiming>? travelByPos,
  String itemFilter = 'all',
  AppLocalizationsEn? l10n,
  int itemOrderEpoch = 0,
}) =>
    TripDerivation.compute(
      trip: trip ?? _trip(),
      bookingTodos: bookingTodos ?? const [],
      stays: stays ?? const [],
      segments: segments ?? const [],
      travelByPos: travelByPos ?? const {},
      itemFilter: itemFilter,
      l10n: l10n ?? _l10n,
      itemOrderEpoch: itemOrderEpoch,
    );

final _l10n = AppLocalizationsEn();

void main() {
  group('memo signature', () {
    test('matches on the identical input signature', () {
      final trip = _trip();
      final todos = [_todo('stay:paris', kind: 'stay')];
      final stays = [_parisStay];
      final segments = <TripSegment>[];
      final travel = {0: _timing(30)};
      final d = _compute(
          trip: trip,
          bookingTodos: todos,
          stays: stays,
          segments: segments,
          travelByPos: travel);
      expect(
        d.matches(
          trip: trip,
          bookingTodos: todos,
          stays: stays,
          segments: segments,
          travelByPos: travel,
          itemFilter: 'all',
          l10n: _l10n,
          itemOrderEpoch: 0,
        ),
        isTrue,
      );
    });

    test('every single input flip invalidates', () {
      final trip = _trip();
      final todos = <BookingTodo>[];
      final stays = <Accommodation>[];
      final segments = <TripSegment>[];
      final travel = <int, LocationTiming>{};
      final d = _compute(
          trip: trip,
          bookingTodos: todos,
          stays: stays,
          segments: segments,
          travelByPos: travel);

      bool matchesWith({
        Trip? newTrip,
        List<BookingTodo>? newTodos,
        List<Accommodation>? newStays,
        List<TripSegment>? newSegments,
        Map<int, LocationTiming>? newTravel,
        String itemFilter = 'all',
        Object? newL10n,
        int epoch = 0,
      }) =>
          d.matches(
            trip: newTrip ?? trip,
            bookingTodos: newTodos ?? todos,
            stays: newStays ?? stays,
            segments: newSegments ?? segments,
            travelByPos: newTravel ?? travel,
            itemFilter: itemFilter,
            l10n: (newL10n ?? _l10n) as AppLocalizationsEn,
            itemOrderEpoch: epoch,
          );

      expect(matchesWith(), isTrue, reason: 'sanity: unchanged inputs reuse');
      // Content-equal but NOT identical objects must invalidate: the screen's
      // mutation paths replace objects wholesale, and identity is the signal.
      expect(matchesWith(newTrip: _trip()), isFalse, reason: 'trip flip');
      expect(matchesWith(newTodos: <BookingTodo>[]), isFalse,
          reason: 'todos flip');
      expect(matchesWith(newStays: <Accommodation>[]), isFalse,
          reason: 'stays flip');
      expect(matchesWith(newSegments: <TripSegment>[]), isFalse,
          reason: 'segments flip');
      expect(matchesWith(newTravel: <int, LocationTiming>{}), isFalse,
          reason: 'travelByPos flip');
      expect(matchesWith(itemFilter: 'attraction'), isFalse,
          reason: 'filter flip');
      expect(matchesWith(newL10n: AppLocalizationsEn()), isFalse,
          reason: 'l10n flip (locale switch delivers a new instance)');
      expect(matchesWith(epoch: 1), isFalse,
          reason: 'epoch flip (the in-place reorder contract)');
    });
  });

  group('lazy per-day accessors', () {
    test('stable List identity per (derivation, day)', () {
      final d = _compute(stays: [_parisStay]);
      expect(identical(d.dayFilteredItems(1), d.dayFilteredItems(1)), isTrue);
      expect(
          identical(d.dayFilteredItems(null), d.dayFilteredItems(null)), isTrue);
      expect(identical(d.dayFilteredItems(null), d.filtered), isTrue);
      expect(identical(d.dayFilteredStays(1), d.dayFilteredStays(1)), isTrue);
      expect(identical(d.dayFilteredStays(null), d.confirmedStays), isTrue);
      expect(identical(d.staysOnNight(2), d.staysOnNight(2)), isTrue);
    });

    test('day filtering matches the legacy per-call rule', () {
      final trip = _trip(stays: [_parisStay, _draftStay]);
      final d = _compute(trip: trip);
      expect([for (final i in d.dayFilteredItems(1)) i.name], ['Louvre']);
      expect([for (final i in d.dayFilteredItems(4)) i.name], ['Trevi']);
      // Confirmed stays only — the auto draft never reaches the map.
      expect([for (final a in d.confirmedStays) a.id], ['a1']);
      // Checkout-exclusive night math: Sep 1 + Sep 2 covered, Sep 3 not.
      expect([for (final a in d.staysOnNight(1)) a.id], ['a1']);
      expect([for (final a in d.staysOnNight(2)) a.id], ['a1']);
      expect(d.staysOnNight(3), isEmpty);
      expect([for (final a in d.dayFilteredStays(2)) a.id], ['a1']);
    });
  });

  group('pipeline parity', () {
    test('groups: revisited city gets a #2 run key and per-run items', () {
      final d = _compute();
      expect([for (final g in d.groups) g.key], ['Paris', 'Rome', 'Paris#2']);
      expect([for (final g in d.groups) g.label], ['Paris', 'Rome', 'Paris']);
      expect([for (final i in d.groups[1].items) i.name],
          ['Colosseum', 'Trevi']);
      expect([for (final i in d.groups[2].items) i.name], ['Louvre Again']);
      // legs (the unfiltered split) mirrors the same runs.
      expect([for (final l in d.legs) l.key], ['Paris', 'Rome', 'Paris#2']);
    });

    test('locationDates: visible (arrival-adjusted) ranges + nights suffix',
        () {
      final d = _compute();
      // Paris days 1-2 → Sep 1 – Sep 2, one night; keyed per item position.
      expect(d.locationDates[0], d.locationDates[1]);
      expect(d.locationDates[0]?.range, 'Sep 1 – Sep 2');
      expect(d.locationDates[0]?.nights, _l10n.tripLegNights(1));
      // Rome renders from its ARRIVAL (previous leg's visible end, Sep 2) —
      // the visibleLegRanges rule the header chips and stay todos share.
      expect(d.locationDates[2]?.range, 'Sep 2 – Sep 4');
      expect(d.locationDates[2]?.nights, _l10n.tripLegNights(2));
      expect(d.locationDates[4]?.range, 'Sep 4 – Sep 5');
      expect(d.locationDates[4]?.nights, _l10n.tripLegNights(1));
      // Group date chips are the same chips, keyed by first item position.
      expect(d.groups[0].dateRange, d.locationDates[0]);
      expect(d.groups[2].dateRange, d.locationDates[4]);

      // A same-day trip collapses to the bare date with no nights suffix.
      final sameDay = _compute(
        trip: Trip(
          id: 't2',
          title: 'Day trip',
          status: 'planned',
          startDate: '2026-09-01',
          endDate: '2026-09-01',
          createdAt: '2026-08-01',
          updatedAt: '2026-08-01',
          items: [
            _item(0, 'Louvre', city: 'Paris', day: 1, lat: 48.86, lng: 2.35)
          ],
        ),
      );
      expect(sameDay.locationDates[0]?.range, 'Sep 1');
      expect(sameDay.locationDates[0]?.nights, isNull);
    });

    test('groupedBookings: claim-once slot matching + residuals', () {
      final todos = [
        _todo('transport:home>>paris'),
        _todo('stay:paris', kind: 'stay'),
        _todo('transport:paris>>rome'),
        _todo('stay:rome', kind: 'stay'),
        _todo('transport:paris>>home'),
        _todo('custom:helicopter', kind: 'other'),
      ];
      final d = _compute(
          bookingTodos: todos, stays: [_parisStay, _draftStay]);
      final grouped = d.groupedBookings;
      // One slot per leg label (Paris, Rome, Paris-revisit).
      expect(d.legLabels, ['Paris', 'Rome', 'Paris']);
      expect(grouped.slots.length, 3);
      expect(grouped.slots[0].arrival?.todoKey, 'transport:home>>paris');
      expect(grouped.slots[0].stay?.todoKey, 'stay:paris');
      expect(grouped.slots[0].stayMatch?.id, 'a1');
      expect(grouped.slots[1].arrival?.todoKey, 'transport:paris>>rome');
      expect(grouped.slots[1].stay?.todoKey, 'stay:rome');
      // Claim-once: the revisited Paris slot cannot re-claim stay:paris.
      expect(grouped.slots[2].stay, isNull);
      // Departure only on the last slot; the inter-city paris>>rome leg was
      // already claimed as Rome's arrival, so the home leg is what's left.
      expect(grouped.slots[0].departure, isNull);
      expect(grouped.slots[2].departure?.todoKey, 'transport:paris>>home');
      // Residuals: the custom todo; the auto draft stay is excluded entirely.
      expect([for (final t in grouped.residual) t.todoKey],
          ['custom:helicopter']);
      expect(grouped.residualStays, isEmpty);
      expect(grouped.residualSegments, isEmpty);
    });

    test('segmentLabels: within-city adjacent legs only, localized', () {
      final travel = {
        0: _timing(30), // Louvre -> Le Comptoir, same hub: labelled
        1: _timing(45), // Le Comptoir -> Colosseum, cross-hub: dropped
        2: _timing(90), // Colosseum -> Trevi, same hub: labelled "1h 30m"
      };
      final d = _compute(travelByPos: travel);
      expect(d.segmentLabels, {0: '30 min', 2: '1h 30m'});
      // A category filter empties the labels (legs aren't globally adjacent).
      final filtered =
          _compute(travelByPos: travel, itemFilter: 'attraction');
      expect(filtered.segmentLabels, isEmpty);
    });

    test('places lenses filter items; bookings lenses keep the whole set', () {
      expect(
        [for (final i in _compute(itemFilter: 'attraction').filtered) i.name],
        ['Louvre', 'Colosseum', 'Trevi', 'Louvre Again'],
      );
      expect(
        [for (final i in _compute(itemFilter: 'local').filtered) i.name],
        ['Le Comptoir'],
      );
      expect(_compute(itemFilter: 'unbooked').filtered.length, 5);
      expect(_compute(itemFilter: 'bookings').filtered.length, 5);
    });

    test('map inputs: shown gate, day chips, destinations, endpoints', () {
      final d = _compute(stays: const []);
      expect(d.mapShown, isTrue);
      expect(d.mapDayCount, 5);
      // Coordinate-bearing items carry days 1, 2, 3, 5 (Trevi has none).
      expect(d.mappedDays, {1, 2, 3, 5});
      // One destination pin per geocoded leg, visit order, dated.
      expect([for (final m in d.mapDestinations) m.label],
          ['Paris', 'Rome', 'Paris']);
      expect(d.mapDestinations[0].dates, 'Sep 1 – Sep 2');
      expect(d.homeLegEndpoints.first?.latitude, 48.86);
      expect(d.homeLegEndpoints.last?.latitude, 48.86);

      // A geocoded stay both shows the map and lights its nights' chips.
      final stayOnly = _compute(
        trip: _trip(items: const [], stays: [_parisStay]),
      );
      expect(stayOnly.mapShown, isTrue);
      expect(stayOnly.mapDayCount, 5);
      expect(stayOnly.mappedDays, {1, 2});

      final bare = _compute(trip: _trip(items: const []));
      expect(bare.mapShown, isFalse);
      expect(bare.groups, isEmpty);
      expect(bare.legLabels, isEmpty);
      expect(bare.groupedBookings.slots, isEmpty);
    });

    test('liveDayKeys + firstGroupKeyForDay follow the run keys', () {
      final d = _compute();
      expect(d.liveDayKeys,
          {'Paris#1', 'Paris#2', 'Rome#3', 'Rome#4', 'Paris#2#5'});
      expect(d.firstGroupKeyForDay(1), 'Paris');
      expect(d.firstGroupKeyForDay(3), 'Rome');
      expect(d.firstGroupKeyForDay(5), 'Paris#2');
      expect(d.firstGroupKeyForDay(9), isNull);
      expect(d.firstGroupKeyForDay(null), isNull);
    });

    test('city fillers keep their group but drop their day keys', () {
      final items = [
        _item(0, 'Prague', city: 'Prague', day: 1, lat: 50.1, lng: 14.4),
        _item(1, 'Charles Bridge',
            city: 'Prague', day: 2, lat: 50.09, lng: 14.41),
      ];
      final d = _compute(trip: _trip(items: items));
      expect(isCityFiller(items[0]), isTrue);
      expect(isCityFiller(items[1]), isFalse);
      // The filler still counts toward its group (suppression is render-side,
      // in _buildGroupItemSlivers)…
      expect(d.groups.single.items.length, 2);
      // …but contributes no day key, mirroring the day-header rule.
      expect(d.liveDayKeys, {'Prague#2'});
    });
  });
}
