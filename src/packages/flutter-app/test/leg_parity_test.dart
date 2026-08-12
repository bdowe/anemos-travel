import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_leg_dto.dart';
import 'package:travel_route_planner/utils/leg_parity.dart';

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city address',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip(List<ItineraryItem> items, List<TripLegDto>? legs) => Trip(
      id: 't1',
      title: 'Parity',
      startDate: '2026-08-24',
      endDate: '2026-08-28',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items,
      legs: legs,
    );

void main() {
  final gothenburgMadrid = [
    _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
    _item(1, 'Liseberg', 'Gothenburg', day: 3),
    _item(2, 'Prado', 'Madrid', day: 5),
  ];

  test('a matching payload yields no mismatches', () {
    // Values mirror the leg_ranges_test.dart visible expectations.
    final trip = _trip(gothenburgMadrid, const [
      TripLegDto(
        key: 'Gothenburg',
        label: 'Gothenburg',
        hub: 'Gothenburg',
        startDate: '2026-08-24',
        endDate: '2026-08-26',
        dateSource: 'items',
        firstPosition: 0,
        lastPosition: 1,
      ),
      TripLegDto(
        key: 'Madrid',
        label: 'Madrid',
        hub: 'Madrid',
        startDate: '2026-08-26',
        endDate: '2026-08-28',
        dateSource: 'items',
        firstPosition: 2,
        lastPosition: 2,
      ),
    ]);
    expect(legParityMismatches(trip), isEmpty);
  });

  test('a divergent payload reports labeled differences', () {
    final trip = _trip(gothenburgMadrid, const [
      TripLegDto(
        key: 'Gothenburg',
        label: 'Gothenburg',
        startDate: '2026-08-24',
        endDate: '2026-08-25', // local says 08-26
        firstPosition: 0,
        lastPosition: 1,
      ),
      TripLegDto(
        key: 'Madrid',
        label: 'Madrid',
        startDate: '2026-08-26',
        endDate: '2026-08-28',
        firstPosition: 2,
        lastPosition: 2,
      ),
    ]);
    final diffs = legParityMismatches(trip);
    // Madrid's payload start (08-26) still equals the LOCAL arrival — the
    // local derivation is self-consistent — so only the end diff reports.
    expect(diffs, hasLength(1));
    expect(diffs[0], contains('Gothenburg end: 2026-08-25 vs 2026-08-26'));
  });

  test('leg-count differences are reported once', () {
    final trip = _trip(gothenburgMadrid, const [
      TripLegDto(
        key: 'Gothenburg',
        label: 'Gothenburg',
        startDate: '2026-08-24',
        endDate: '2026-08-26',
        firstPosition: 0,
        lastPosition: 1,
      ),
    ]);
    final diffs = legParityMismatches(trip);
    expect(diffs.first, contains('leg count: payload 1 vs local 2'));
  });

  test('a payload without legs compares nothing', () {
    expect(legParityMismatches(_trip(gothenburgMadrid, null)), isEmpty);
  });
}
