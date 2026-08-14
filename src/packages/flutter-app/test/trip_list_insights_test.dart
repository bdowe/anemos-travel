import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/city_pin.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/utils/trip_list_insights.dart';

/// List-payload insight derivations (utils/trip_list_insights.dart): lifetime
/// stats, footprint pins, and the booking-nudge window — plus the Trip model's
/// tolerance for payloads with and without the new insight keys.

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
  group('lifetimeStats', () {
    test('counts all trips and sums dated spans; undated contribute zero days',
        () {
      final s = lifetimeStats([
        _trip('dated', start: '2026-08-20', end: '2026-08-24'), // 5 days
        _trip('draft'),
      ]);
      expect(s.trips, 2);
      expect(s.travelDays, 5);
      expect(s.cities, 0);
    });

    test('is all-time: past and upcoming trips both count', () {
      final s = lifetimeStats([
        _trip('past',
            start: '2026-01-01', end: '2026-01-05', // 5 days, long over
            cities: const ['Lisbon']),
        _trip('future',
            start: '2026-09-01', end: '2026-09-03', // 3 days
            cities: const ['Madrid']),
      ]);
      expect(s.trips, 2);
      expect(s.travelDays, 8);
      expect(s.cities, 2);
    });

    test('dedupes cities case- and whitespace-insensitively across trips', () {
      final s = lifetimeStats([
        _trip('a', cities: const ['Lisbon', 'Porto']),
        _trip('b', cities: const [' lisbon ', 'PORTO', 'Madrid']),
      ]);
      expect(s.cities, 3);
    });

    test('an empty list yields all zeros', () {
      final s = lifetimeStats(const []);
      expect(s.trips, 0);
      expect(s.travelDays, 0);
      expect(s.cities, 0);
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
      ]);
      expect(pins.map((p) => p.city), ['Lisbon', 'Porto', 'Madrid']);
    });

    test('dedupes case-insensitively; the first coordinate wins', () {
      final pins = footprintPins([
        _trip('a', pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
        _trip('b', pins: const [
          CityPin(city: ' LISBON ', lat: 0.1, lng: 0.2), // revisit — ignored
          CityPin(city: 'Athens', lat: 37.9, lng: 23.7),
        ]),
      ]);
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
      ]);
      expect(pins.map((p) => p.city), ['Lisbon']);
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
