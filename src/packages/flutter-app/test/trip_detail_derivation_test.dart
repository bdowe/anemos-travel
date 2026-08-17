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

BookingTodo _todo(String key,
        {String kind = 'transport', bool booked = false}) =>
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
  AppLocalizationsEn? l10n,
  int itemOrderEpoch = 0,
}) =>
    TripDerivation.compute(
      trip: trip ?? _trip(),
      bookingTodos: bookingTodos ?? const [],
      stays: stays ?? const [],
      segments: segments ?? const [],
      travelByPos: travelByPos ?? const {},
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
        Object? newL10n,
        int epoch = 0,
      }) =>
          d.matches(
            trip: newTrip ?? trip,
            bookingTodos: newTodos ?? todos,
            stays: newStays ?? stays,
            segments: newSegments ?? segments,
            travelByPos: newTravel ?? travel,
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
      expect(matchesWith(newL10n: AppLocalizationsEn()), isFalse,
          reason: 'l10n flip (locale switch delivers a new instance)');
      expect(matchesWith(epoch: 1), isFalse,
          reason: 'epoch flip (the in-place reorder contract)');
    });
  });

  group('staysOnNight (the Tonight-caption night math)', () {
    test('stable List identity per (derivation, day)', () {
      final d = _compute(stays: [_parisStay]);
      expect(identical(d.staysOnNight(2), d.staysOnNight(2)), isTrue);
    });

    test('checkout-exclusive, confirmed stays only', () {
      final trip = _trip(stays: [_parisStay, _draftStay]);
      final d = _compute(trip: trip);
      // Confirmed stays only — the auto draft never reaches the map.
      expect([for (final a in d.confirmedStays) a.id], ['a1']);
      // Checkout-exclusive night math: Sep 1 + Sep 2 covered, Sep 3 not.
      expect([for (final a in d.staysOnNight(1)) a.id], ['a1']);
      expect([for (final a in d.staysOnNight(2)) a.id], ['a1']);
      expect(d.staysOnNight(3), isEmpty);
    });
  });

  group('pipeline parity', () {
    test('groups: revisited city gets a #2 run key and per-run items', () {
      final d = _compute();
      expect([for (final g in d.groups) g.key], ['Paris', 'Rome', 'Paris#2']);
      expect([for (final g in d.groups) g.label], ['Paris', 'Rome', 'Paris']);
      expect(
          [for (final i in d.groups[1].items) i.name], ['Colosseum', 'Trevi']);
      expect([for (final i in d.groups[2].items) i.name], ['Louvre Again']);
      // legs (the unfiltered split) mirrors the same runs.
      expect([for (final l in d.legs) l.key], ['Paris', 'Rome', 'Paris#2']);
    });

    test('groups: same-label runs carry distinct header qualifiers', () {
      // The two Paris runs share a label, so the city headers would read
      // identically — which is how a duplicate city looked like a rendering
      // bug rather than two real runs. They borrow the map chips' qualifier.
      final d = _compute();
      expect(d.groups[0].label, d.groups[2].label);
      expect(d.groups[0].qualifier, isNotNull);
      expect(d.groups[2].qualifier, isNotNull);
      expect(d.groups[0].qualifier, isNot(d.groups[2].qualifier));
      // The lone Rome run needs no disambiguation.
      expect(d.groups[1].qualifier, isNull);
      // Qualifiers stay OUT of the label: callers speak it in a sentence.
      expect(d.groups[0].label, 'Paris');
      // ...and agree with the map chips, which run the same derivation.
      expect([for (final g in d.groups) g.qualifier],
          [for (final c in d.legChips) c.qualifier]);
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
      final d = _compute(bookingTodos: todos, stays: [_parisStay, _draftStay]);
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
      expect(
          [for (final t in grouped.residual) t.todoKey], ['custom:helicopter']);
      expect(grouped.residualStays, isEmpty);
      expect(grouped.residualSegments, isEmpty);
    });

    // The Bookings filter strip's chip counts. The rule they must obey is the
    // one PR #455 paid for on the Trip Health badge: a count answers for the
    // rows it sits above, so it counts ENTRIES (one visible checkbox each)
    // over exactly the slots that chip reveals.
    test('bookingDestinationCounts: one entry per visible checkbox', () {
      final todos = [
        _todo('transport:home>>paris'),
        _todo('stay:paris', kind: 'stay', booked: true),
        _todo('transport:paris>>rome'),
        _todo('stay:rome', kind: 'stay'),
        _todo('transport:paris>>home'),
        _todo('custom:helicopter', kind: 'other', booked: true),
      ];
      final d = _compute(bookingTodos: todos, stays: [_parisStay, _draftStay]);
      final counts = bookingDestinationCounts(d.groupedBookings, d.legLabels,
          otherKey: 'Other places');

      // Paris' two runs sum into ONE entry: run 1 has an arrival + a booked
      // stay; the revisited run has the flight home (departure counts only on
      // the LAST slot) and no stay to re-claim.
      expect(counts['Paris'], (booked: 1, total: 3));
      expect(counts['Rome'], (booked: 0, total: 2));
      // Residuals answer under Other, and only there.
      expect(counts['Other places'], (booked: 1, total: 1));
    });

    test('bookingDestinationCounts: a stay match rides its todo, not a second '
        'entry', () {
      final todos = [_todo('stay:paris', kind: 'stay')];
      final d = _compute(bookingTodos: todos, stays: [_parisStay]);
      final grouped = d.groupedBookings;
      // The confirmed stay filled the todo's slot...
      expect(grouped.slots[0].stayMatch?.id, 'a1');
      // ...so it is ONE booking, not two, and its checkbox is the todo's.
      expect(
          bookingDestinationCounts(grouped, d.legLabels, otherKey: 'Other')[
              'Paris'],
          (booked: 0, total: 1));
    });

    test('bookingEntryBooked: the todo wins, then the record', () {
      const bookedStay = Accommodation(id: 'a9', name: 'X', booked: true);
      expect(
          bookingEntryBooked(
              (todo: _todo('stay:x', kind: 'stay'), stay: bookedStay, segment: null)),
          isFalse,
          reason: 'an unticked todo row is unbooked whatever its match says');
      expect(bookingEntryBooked((todo: null, stay: bookedStay, segment: null)),
          isTrue);
      expect(bookingEntryBooked((todo: null, stay: null, segment: null)), isTrue,
          reason: 'nothing to book never lands in the left-to-book list');
    });

    // A confirmed segment fills a leg's slot only when it connects BOTH of the
    // leg's endpoints — the rule the server has always applied in todoClaimed
    // (trip_review.go), now applied here too.
    //
    // The friction that produced the trip-airports control: correcting the
    // airport inside "Add details…" POSTed "ALB → Paris", and the page nested
    // it under the "EWR → Paris" leg on the destination alone. The page read
    // as covered while Trip Health went on counting the flight as a gap.
    test('groupedBookings: a segment must connect BOTH ends of a leg', () {
      final trip = _trip(items: [
        _item(0, 'Louvre', city: 'Paris', day: 1, lat: 48.86, lng: 2.35),
      ]);
      final todos = [_todo('transport:ewr>>paris'), _todo('stay:paris', kind: 'stay')];

      final mismatched = _compute(
        trip: trip,
        bookingTodos: todos,
        segments: const [
          TripSegment(
              id: 's1', mode: 'flight', origin: 'ALB', destination: 'Paris'),
        ],
      ).groupedBookings;
      expect(mismatched.slots.first.arrivalMatch, isNull,
          reason: 'a segment from a different airport is not this leg');
      // It is still the traveler's booking — it lands in "Other bookings"
      // rather than vanishing or masquerading as the leg above it.
      expect([for (final s in mismatched.residualSegments) s.id], ['s1']);

      final matching = _compute(
        trip: trip,
        bookingTodos: todos,
        segments: const [
          TripSegment(
              id: 's2', mode: 'flight', origin: 'EWR', destination: 'Paris'),
        ],
      ).groupedBookings;
      expect(matching.slots.first.arrivalMatch?.id, 's2');
      expect(matching.residualSegments, isEmpty);
    });

    test('segmentLabels: within-city adjacent legs only, localized', () {
      final travel = {
        0: _timing(30), // Louvre -> Le Comptoir, same hub: labelled
        1: _timing(45), // Le Comptoir -> Colosseum, cross-hub: dropped
        2: _timing(90), // Colosseum -> Trevi, same hub: labelled "1h 30m"
      };
      final d = _compute(travelByPos: travel);
      expect(d.segmentLabels, {0: '30 min', 2: '1h 30m'});
    });

    test('map inputs: shown gate, destinations, endpoints', () {
      final d = _compute(stays: const []);
      expect(d.mapShown, isTrue);
      // One destination pin per geocoded leg, visit order, dated.
      expect([for (final m in d.mapDestinations) m.label],
          ['Paris', 'Rome', 'Paris']);
      expect(d.mapDestinations[0].dates, 'Sep 1 – Sep 2');
      expect(d.homeLegEndpoints.first?.latitude, 48.86);
      expect(d.homeLegEndpoints.last?.latitude, 48.86);

      // A geocoded stay shows the map on its own.
      final stayOnly = _compute(
        trip: _trip(items: const [], stays: [_parisStay]),
      );
      expect(stayOnly.mapShown, isTrue);
      expect(stayOnly.legChips, isEmpty);

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

    test('legChips: full-leg keys in visit order, localized labels', () {
      final d = _compute();
      expect([for (final c in d.legChips) c.key], ['Paris', 'Rome', 'Paris#2']);
      expect([for (final c in d.legChips) c.label], ['Paris', 'Rome', 'Paris']);
      // A single-leg trip still yields its one entry — hiding the <2-leg
      // strip is the widget's rule, so the gate has one home.
      final solo = _compute(
        trip: _trip(items: [
          _item(0, 'Louvre', city: 'Paris', day: 1, lat: 48.86, lng: 2.35),
        ]),
      );
      expect(solo.legChips.length, 1);
      // The 'Other places' run keeps the raw registry key, localized label.
      final other = _compute(
        trip: _trip(items: [
          _item(0, 'Louvre', city: 'Paris', day: 1, lat: 48.86, lng: 2.35),
          const ItineraryItem(
            id: 'i-mystery',
            position: 1,
            name: 'Mystery spot',
            latitude: 0,
            longitude: 0,
          ),
        ]),
      );
      expect(other.legChips[1].key, 'Other places');
      expect(other.legChips[1].label, _l10n.tripOtherPlaces);
    });

    test('mappedLegKeys: geocoded items, stay-only legs, unmapped legs', () {
      // Default fixture: every leg has a geocoded item.
      expect(_compute().mappedLegKeys, {'Paris', 'Rome', 'Paris#2'});

      // Rome loses its coordinates and has no stay → unmapped (muted chip).
      final items = [
        _item(0, 'Louvre', city: 'Paris', day: 1, lat: 48.86, lng: 2.35),
        _item(1, 'Colosseum', city: 'Rome', day: 3),
      ];
      final bare = _compute(trip: _trip(items: items));
      expect(bare.mappedLegKeys, {'Paris'});

      // A geocoded stay covering Rome's nights lights the leg back up.
      const romeStay = Accommodation(
        id: 'a3',
        name: 'Rome Inn',
        address: 'Via Y, Rome',
        latitude: 41.9,
        longitude: 12.5,
        checkIn: '2026-09-03',
        checkOut: '2026-09-05',
      );
      final withStay = _compute(trip: _trip(items: items, stays: [romeStay]));
      expect(withStay.mappedLegKeys, {'Paris', 'Rome'});
    });

    test('legFilteredItems: the leg\'s own run, All = the whole set', () {
      final d = _compute();
      expect(d.items.length, 5, reason: 'the full itinerary, always');
      expect([for (final i in d.legFilteredItems('Rome')) i.name],
          ['Colosseum', 'Trevi']);
      expect([for (final i in d.legFilteredItems('Paris#2')) i.name],
          ['Louvre Again']);
      expect(d.legFilteredItems('Nowhere'), isEmpty);
      expect(identical(d.legFilteredItems(null), d.items), isTrue);
      expect(identical(d.legFilteredItems('Rome'), d.legFilteredItems('Rome')),
          isTrue,
          reason: 'stable identity per (derivation, key)');
    });

    test('legFilteredStays: raw-range night overlap, checkout-exclusive', () {
      // _parisStay (Sep 1 → Sep 3) anchors Paris to Sep 1–Sep 3: nights
      // Sep 1 + Sep 2. Rome (days 3-4) spans Sep 3–Sep 4: night Sep 3 only.
      final d = _compute(trip: _trip(stays: [_parisStay]));
      expect([for (final a in d.legFilteredStays('Paris')) a.id], ['a1']);
      // Checkout Sep 3 is exclusive → the stay covers no Rome night.
      expect(d.legFilteredStays('Rome'), isEmpty);
      // The revisit shares its locality's stay-anchored range (rawLegRanges'
      // first-matching-accommodation rule), so the city's stay plots on a
      // Paris#2 focus too — same city, same pin.
      expect([for (final a in d.legFilteredStays('Paris#2')) a.id], ['a1']);
      expect(identical(d.legFilteredStays(null), d.confirmedStays), isTrue);
      expect(
          identical(d.legFilteredStays('Paris'), d.legFilteredStays('Paris')),
          isTrue,
          reason: 'stable identity per (derivation, key)');
      expect(d.legFilteredStays('Nowhere'), isEmpty);

      // A zero-night squeezed leg plots no stays — even one covering the
      // calendar night the leg sits on belongs to the neighbor.
      const viennaStay = Accommodation(
        id: 'a4',
        name: 'Vienna Hotel',
        address: 'Ring 1, Vienna',
        latitude: 48.2,
        longitude: 16.37,
        checkIn: '2026-09-04',
        checkOut: '2026-09-06',
      );
      final squeezed = _compute(
        trip: _trip(
          items: [
            _item(0, 'Belvedere',
                city: 'Vienna', day: 1, lat: 48.19, lng: 16.38),
            _item(1, 'Castle', city: 'Prague', day: 5, lat: 50.09, lng: 14.4),
          ],
          stays: [viennaStay],
        ),
      );
      expect(squeezed.legFilteredStays('Prague'), isEmpty);
      expect(
          [for (final a in squeezed.legFilteredStays('Vienna')) a.id], ['a4']);

      // An undated leg (no parseable range) plots no stays.
      final undated = _compute(
        trip: Trip(
          id: 't3',
          title: 'No dates',
          createdAt: '2026-08-01',
          updatedAt: '2026-08-01',
          items: _items(),
          accommodations: const [_parisStay],
        ),
      );
      expect(undated.legFilteredStays('Rome'), isEmpty);
    });

    test('legKeyForDay / legKeyOfPosition / legIndexOf / dayForLeg', () {
      final d = _compute();
      expect(d.legKeyForDay(1), 'Paris');
      // Resolves on the day TAG, geocoded or not (Trevi has no coords).
      expect(d.legKeyForDay(4), 'Rome');
      expect(d.legKeyForDay(5), 'Paris#2');
      expect(d.legKeyForDay(9), isNull);
      expect(d.legKeyForDay(null), isNull);

      expect(d.legKeyOfPosition(0), 'Paris');
      expect(d.legKeyOfPosition(3), 'Rome');
      expect(d.legKeyOfPosition(4), 'Paris#2');
      expect(d.legKeyOfPosition(99), isNull);

      expect(d.legIndexOf('Paris'), 0);
      expect(d.legIndexOf('Paris#2'), 2);
      expect(d.legIndexOf('Nope'), isNull);

      expect(d.dayForLeg('Rome'), 3, reason: 'smallest day tag wins');
      expect(d.dayForLeg(null), isNull);
      expect(d.dayForLeg('Nope'), isNull);

      // A day-less leg falls back to its raw range's trip-start offset:
      // Paris pins Sep 1, the auto allocation hands Rome Sep 4–Sep 5.
      final dayless = _compute(
        trip: _trip(items: [
          _item(0, 'Louvre', city: 'Paris', day: 1, lat: 48.86, lng: 2.35),
          _item(1, 'Colosseum', city: 'Rome', lat: 41.89, lng: 12.49),
        ]),
      );
      expect(dayless.dayForLeg('Rome'), 4);
    });

    test('groupKeyForLeg: identity for live keys, null for stale ones', () {
      // Groups run the same split as legs: identity, clamped.
      final d = _compute();
      expect(d.groupKeyForLeg('Paris'), 'Paris');
      expect(d.groupKeyForLeg('Rome'), 'Rome');
      expect(d.groupKeyForLeg('Paris#2'), 'Paris#2');
      expect(d.groupKeyForLeg('Nowhere'), isNull, reason: 'stale keys clamp');
      expect(d.groupKeyForLeg(null), isNull);
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

  // TWIN of TestIsCityFillerParity in api/city_filler_test.go. Same cases, same
  // expectations, in the same order — docs/zen.md requires the parity contract
  // because "city filler" has two implementations now: this one, which HIDES
  // these rows, and the server's, which must not count what this one hides
  // (a 37-day trip of bare city pins used to check "Plan your days" off).
  // Change one table, change the other.
  group('isCityFiller parity with the Go server', () {
    // dartOnly marks the ONE documented divergence: this predicate compares the
    // name against cityOf(), which falls back to a regex over the address when
    // the city field is empty. The server reads the explicit columns only —
    // a second regex would drift, and AI-emitted fillers always set city.
    final cases =
        <({String desc, ItineraryItem item, bool want, bool dartOnly})>[
      (
        desc: 'name equals city',
        item: _filler(name: 'Prague', city: 'Prague'),
        want: true,
        dartOnly: false
      ),
      (
        desc: 'real activity in a city',
        item: _filler(name: 'Charles Bridge', city: 'Prague'),
        want: false,
        dartOnly: false
      ),
      (
        desc: 'case and space insensitive',
        item: _filler(name: '  prague ', city: 'Prague'),
        want: true,
        dartOnly: false
      ),
      (
        desc: 'name equals the day-trip hub',
        item: _filler(name: 'Kyoto', city: 'Nara', dayTripFrom: 'Kyoto'),
        want: true,
        dartOnly: false
      ),
      (
        desc: 'hub set, name is a real place',
        item:
            _filler(name: 'Fushimi Inari', city: 'Nara', dayTripFrom: 'Kyoto'),
        want: false,
        dartOnly: false
      ),
      (
        desc: 'no city and no hub',
        item: _filler(name: 'Prague'),
        want: false,
        dartOnly: false
      ),
      (
        desc: 'empty name is never a filler',
        item: _filler(name: '   ', city: 'Prague'),
        want: false,
        dartOnly: false
      ),
      (
        desc: 'city empty, name matches the address city',
        item: _filler(
            name: 'Prague', city: '', address: 'Old Town, Prague, Czechia'),
        want: true,
        dartOnly: true
      ),
    ];

    for (final c in cases) {
      test(c.desc, () {
        expect(isCityFiller(c.item), c.want,
            reason: c.dartOnly
                ? 'documented divergence: the Go twin expects false here'
                : 'the Go twin must agree');
      });
    }
  });
}

/// Bare item for the parity table — no address is synthesized (unlike [_item]),
/// because the address is one of the inputs under test.
ItineraryItem _filler({
  required String name,
  String? city,
  String? dayTripFrom,
  String? address,
}) =>
    ItineraryItem(
      id: 'filler-$name',
      position: 0,
      name: name,
      address: address,
      latitude: 0,
      longitude: 0,
      city: city,
      dayTripFrom: dayTripFrom,
    );
