import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/city_pin.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/utils/trip_list_insights.dart';

/// List-payload insight derivations (utils/trip_list_insights.dart): the
/// traveled/planned split, footprint pins, and the booking-nudge window — plus
/// the Trip model's tolerance for payloads with and without the insight keys.

Trip _trip(
  String id, {
  String? start,
  String? end,
  List<String>? cities,
  List<CityPin>? pins,
  String? nextTransportDepart,
  String created = '2026-06-01T00:00:00Z',
}) =>
    Trip(
      id: id,
      title: id,
      startDate: start,
      endDate: end,
      cities: cities,
      cityPins: pins,
      nextTransportDepart: nextTransportDepart,
      createdAt: created,
      updatedAt: created,
    );

// A fixed "today" keeps every case deterministic.
final _today = DateTime(2026, 8, 6);

void main() {
  group('travelStats', () {
    test('a finished trip is traveled in full; a future one is planned', () {
      final s = travelStats([
        _trip('past',
            start: '2026-01-01', end: '2026-01-05', // 5 days, long over
            cities: const ['Lisbon']),
        _trip('future',
            start: '2026-09-01', end: '2026-09-03', // 3 days
            cities: const ['Madrid']),
      ], _today);
      expect(s.traveled, (trips: 1, travelDays: 5, cities: 1));
      expect(s.planned, (trips: 1, travelDays: 3, cities: 1));
    });

    test('an in-progress trip counts only the days lived through so far', () {
      // Day 1 was Aug 4; today is Aug 6 ⇒ 3 of the 10 days are behind us. The
      // remaining 7 belong to neither side: each side stays consistent with
      // the trips shown beside it.
      final s = travelStats([
        _trip('live', start: '2026-08-04', end: '2026-08-13', cities: const [
          'Athens',
          'Naxos',
        ]),
      ], _today);
      expect(s.traveled, (trips: 1, travelDays: 3, cities: 2));
      expect(s.planned, (trips: 0, travelDays: 0, cities: 0));
    });

    // A logged past trip (specs/log-past-trip) is an ORDINARY trip with past
    // dates and hub cities, so it must need no special handling here — that is
    // the whole reason the feature saves a real trip rather than keeping a
    // separate visited-places store. Pinned because a change to the bucketing
    // rule would otherwise strand every logged trip on the wrong side silently.
    test('a logged past trip counts as traveled, pins and all', () {
      const pins = [
        CityPin(city: 'Kyoto', lat: 35.0116, lng: 135.7681),
        CityPin(city: 'Osaka', lat: 34.6937, lng: 135.5023),
      ];
      final trips = [
        // Server order is newest-created-first, so the logged trip — created
        // today, travelled years ago — lands FIRST, ahead of the upcoming one.
        _trip('logged',
            start: '2019-03-03',
            end: '2019-03-17', // 15 days
            cities: const ['Kyoto', 'Osaka', "Grandma's village"],
            pins: pins,
            created: '2026-08-06T00:00:00Z'),
        _trip('upcoming',
            start: '2026-09-01', end: '2026-09-03', cities: const ['Madrid']),
      ];
      final s = travelStats(trips, _today);
      // The name-only destination carries no coordinates but is still a city.
      expect(s.traveled, (trips: 1, travelDays: 15, cities: 3));
      expect(s.planned, (trips: 1, travelDays: 3, cities: 1));

      final footprint = footprintPins(trips, _today);
      expect(footprint.map((p) => p.city), ['Kyoto', 'Osaka']);
      expect(footprint.every((p) => p.visited), isTrue,
          reason: 'a logged past trip earns filled dots, not hollow ones');
    });

    test('a trip starting today has started (1 day travelled)', () {
      final s = travelStats(
          [_trip('t', start: '2026-08-06', end: '2026-08-08')], _today);
      expect(s.traveled.trips, 1);
      expect(s.traveled.travelDays, 1);
      expect(s.planned.trips, 0);
    });

    test('a trip starting tomorrow is still planned, at its full span', () {
      final s = travelStats(
          [_trip('t', start: '2026-08-07', end: '2026-08-09')], _today);
      expect(s.traveled.trips, 0);
      expect(s.planned, (trips: 1, travelDays: 3, cities: 0));
    });

    test('undated drafts are planned and contribute no days', () {
      final s = travelStats([
        _trip('draft', cities: const ['Tokyo']),
        _trip('dated', start: '2026-08-20', end: '2026-08-24'), // 5 days
      ], _today);
      expect(s.traveled, (trips: 0, travelDays: 0, cities: 0));
      expect(s.planned, (trips: 2, travelDays: 5, cities: 1));
    });

    test('a half-dated trip buckets by its one date but adds no days', () {
      // start-only in the past: the list files it under Past trips, so the
      // band must agree it has been travelled — dayCount needs both dates,
      // so it lands there with 0 days rather than sitting among the plans.
      final s = travelStats([_trip('t', start: '2026-05-01')], _today);
      expect(s.traveled, (trips: 1, travelDays: 0, cities: 0));
      expect(s.planned.trips, 0);
    });

    test('dedupes cities case- and whitespace-insensitively within a side', () {
      final s = travelStats([
        _trip('a', start: '2026-09-01', end: '2026-09-03', cities: const [
          'Lisbon',
          'Porto',
        ]),
        _trip('b', start: '2026-10-01', end: '2026-10-03', cities: const [
          ' lisbon ',
          'PORTO',
          'Madrid',
        ]),
      ], _today);
      expect(s.planned.cities, 3);
    });

    test('a city on both sides counts once, as traveled', () {
      final s = travelStats([
        // Newest-created first, exactly like the server's order: the planned
        // trip is seen BEFORE the past one that actually visited Lisbon.
        _trip('return', start: '2026-09-01', end: '2026-09-03', cities: const [
          'Lisbon',
          'Madrid',
        ]),
        _trip('first', start: '2026-01-01', end: '2026-01-05', cities: const [
          'Lisbon',
        ]),
      ], _today);
      expect(s.traveled.cities, 1); // Lisbon
      expect(s.planned.cities, 1); // Madrid only
    });

    test('an empty list yields two zeroed sides', () {
      final s = travelStats(const [], _today);
      expect(s.traveled, (trips: 0, travelDays: 0, cities: 0));
      expect(s.planned, (trips: 0, travelDays: 0, cities: 0));
    });
  });

  group('bookingNudgeDate', () {
    test('returns the departure inside the window', () {
      final d = bookingNudgeDate(
          _trip('t', nextTransportDepart: '2026-08-11'), _today); // 5 days out
      expect(d, DateTime.parse('2026-08-11'));
    });

    test('departing today (0 days) still nudges', () {
      expect(
        bookingNudgeDate(_trip('t', nextTransportDepart: '2026-08-06'), _today),
        DateTime.parse('2026-08-06'),
      );
    });

    test('exactly kBookingNudgeWindowDays out nudges; one past it does not',
        () {
      expect(
        bookingNudgeDate(
            _trip('t', nextTransportDepart: '2026-08-20'), _today), // 14
        DateTime.parse('2026-08-20'),
      );
      expect(
        bookingNudgeDate(
            _trip('t', nextTransportDepart: '2026-08-21'), _today), // 15
        isNull,
      );
    });

    test('a stale-cache past departure never nudges', () {
      // Server guarantees future-only, but the cached row can age past it.
      expect(
        bookingNudgeDate(_trip('t', nextTransportDepart: '2026-08-05'), _today),
        isNull,
      );
    });

    test('unparseable and null fields yield no nudge', () {
      expect(
        bookingNudgeDate(_trip('t', nextTransportDepart: 'not-a-date'), _today),
        isNull,
      );
      expect(bookingNudgeDate(_trip('t'), _today), isNull);
    });
  });

  group('footprintPins', () {
    test('flattens pins in list order', () {
      final pins = footprintPins([
        _trip('a', pins: const [
          CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1),
          CityPin(city: 'Porto', lat: 41.1, lng: -8.6),
        ]),
        _trip('b', pins: const [
          CityPin(city: 'Madrid', lat: 40.4, lng: -3.7),
        ]),
      ], _today);
      expect(pins.map((p) => p.city), ['Lisbon', 'Porto', 'Madrid']);
    });

    test('dedupes case-insensitively; the first coordinate wins', () {
      final pins = footprintPins([
        _trip('a', pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
        _trip('b', pins: const [
          CityPin(city: ' LISBON ', lat: 0.1, lng: 0.2), // revisit — ignored
          CityPin(city: 'Athens', lat: 37.9, lng: 23.7),
        ]),
      ], _today);
      expect(pins, hasLength(2));
      expect(pins[0].city, 'Lisbon');
      expect(pins[0].lat, 38.7);
      expect(pins[1].city, 'Athens');
    });

    test('trips without pins (old server / shared rows) contribute nothing',
        () {
      final pins = footprintPins([
        _trip('bare'),
        _trip('a', pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
      ], _today);
      expect(pins.map((p) => p.city), ['Lisbon']);
    });

    test('visited tracks whether the trip has started', () {
      final pins = footprintPins([
        _trip('past',
            start: '2026-01-01',
            end: '2026-01-05',
            cities: const ['Lisbon'],
            pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
        _trip('future',
            start: '2026-09-01',
            end: '2026-09-03',
            cities: const ['Madrid'],
            pins: const [CityPin(city: 'Madrid', lat: 40.4, lng: -3.7)]),
      ], _today);
      expect(pins.map((p) => p.visited), [true, false]);
    });

    test('a visited city stays visited when a PLANNED trip wins its coordinate',
        () {
      // Server order is newest-created-first, so the upcoming return trip
      // supplies the winning pin for a city the traveler has already been to.
      // Reading `visited` off that row would hollow out an earned dot.
      final pins = footprintPins([
        _trip('return',
            start: '2026-09-01',
            end: '2026-09-03',
            cities: const ['Lisbon'],
            pins: const [CityPin(city: ' lisbon ', lat: 38.7, lng: -9.1)]),
        _trip('first',
            start: '2026-01-01',
            end: '2026-01-05',
            cities: const ['Lisbon'],
            pins: const [CityPin(city: 'Lisbon', lat: 38.71, lng: -9.14)]),
      ], _today);
      expect(pins, hasLength(1));
      expect(pins.single.visited, isTrue);
    });

    test('an undated draft pins as planned', () {
      final pins = footprintPins([
        _trip('draft',
            cities: const ['Tokyo'],
            pins: const [CityPin(city: 'Tokyo', lat: 35.7, lng: 139.7)]),
      ], _today);
      expect(pins.single.visited, isFalse);
    });
  });

  group('Trip insight fields JSON', () {
    test('a payload with every insight key populates and round-trips', () {
      final trip = Trip.fromJson({
        'id': 't1',
        'title': 'Fixture',
        'created_at': '2026-08-01',
        'updated_at': '2026-08-01',
        'stay_total': 2,
        'stay_booked': 1,
        'packing_total': 20,
        'packing_done': 12,
        // Integral JSON — Go's encoder drops the ".0" on whole floats; the
        // double? fields must tolerate it (num?.toDouble()).
        'budget_target': 800,
        'budget_spent': 540.5,
        'budget_currency': 'EUR',
        'next_transport_depart': '2026-08-24',
        'city_pins': [
          {'city': 'Lisbon', 'lat': 38.7, 'lng': -9.1},
          {'city': 'Porto', 'lat': 41, 'lng': -8},
        ],
      });

      expect(trip.stayTotal, 2);
      expect(trip.stayBooked, 1);
      expect(trip.packingTotal, 20);
      expect(trip.packingDone, 12);
      expect(trip.budgetTarget, 800.0);
      expect(trip.budgetSpent, 540.5);
      expect(trip.budgetCurrency, 'EUR');
      expect(trip.nextTransportDepart, '2026-08-24');
      expect(trip.cityPins, hasLength(2));
      expect(trip.cityPins![0].city, 'Lisbon');
      expect(trip.cityPins![1].lat, 41.0);

      // Offline cache path: toJson → fromJson must preserve every field.
      final back = Trip.fromJson(trip.toJson());
      expect(back.stayTotal, 2);
      expect(back.stayBooked, 1);
      expect(back.packingTotal, 20);
      expect(back.packingDone, 12);
      expect(back.budgetTarget, 800.0);
      expect(back.budgetSpent, 540.5);
      expect(back.budgetCurrency, 'EUR');
      expect(back.nextTransportDepart, '2026-08-24');
      expect(back.cityPins!.map((p) => p.city), ['Lisbon', 'Porto']);
      expect(back.cityPins![0].lng, -9.1);
    });

    test('a payload without the insight keys parses to all-null (old server)',
        () {
      final trip = Trip.fromJson({
        'id': 't1',
        'title': 'Fixture',
        'created_at': '2026-08-01',
        'updated_at': '2026-08-01',
      });
      expect(trip.stayTotal, isNull);
      expect(trip.stayBooked, isNull);
      expect(trip.packingTotal, isNull);
      expect(trip.packingDone, isNull);
      expect(trip.budgetTarget, isNull);
      expect(trip.budgetSpent, isNull);
      expect(trip.budgetCurrency, isNull);
      expect(trip.nextTransportDepart, isNull);
      expect(trip.cityPins, isNull);
    });
  });
}
