import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/utils/trip_legs.dart';

ItineraryItem _item(
  int pos, {
  String name = 'Stop',
  String? city,
  String? dayTripFrom,
  String? address,
  double lat = 0,
  double lng = 0,
}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      city: city,
      dayTripFrom: dayTripFrom,
      address: address,
    );

void main() {
  group('tripLegs', () {
    test('splits consecutive same-locality runs in itinerary order', () {
      final legs = tripLegs([
        _item(0, city: 'Paris', lat: 48.86, lng: 2.34),
        _item(1, city: 'Paris', lat: 48.85, lng: 2.33),
        _item(2, city: 'Rome', lat: 41.9, lng: 12.5),
      ]);

      expect(legs.map((l) => l.label), ['Paris', 'Rome']);
      expect(legs.map((l) => l.key), ['Paris', 'Rome']);
      expect(legs.first.items.map((i) => i.position), [0, 1]);
      expect(legs.last.items.map((i) => i.position), [2]);
    });

    test('day trips fold under their hub city', () {
      final legs = tripLegs([
        _item(0, city: 'Paris'),
        _item(1, city: 'Versailles', dayTripFrom: 'Paris'),
        _item(2, city: 'Paris'),
      ]);

      expect(legs, hasLength(1));
      expect(legs.single.label, 'Paris');
      expect(legs.single.items, hasLength(3));
    });

    test('null localities group together but never adopt neighbors', () {
      final legs = tripLegs([
        _item(0, city: 'Paris'),
        _item(1), // no city, no address
        _item(2),
        _item(3, city: 'Paris'),
      ]);

      expect(legs.map((l) => l.label), ['Paris', kOtherPlacesLabel, 'Paris']);
      expect(legs[1].locality, isNull);
      expect(legs[1].items, hasLength(2));
      // Run identity survives the revisit around the unresolved run.
      expect(legs.map((l) => l.key), ['Paris', kOtherPlacesLabel, 'Paris#2']);
    });

    test('revisited cities get #2/#3 keys with a shared label', () {
      final legs = tripLegs([
        _item(0, city: 'Athens'),
        _item(1, city: 'Fira'),
        _item(2, city: 'Oia'),
        _item(3, city: 'Fira'),
      ]);

      expect(legs.map((l) => l.label), ['Athens', 'Fira', 'Oia', 'Fira']);
      expect(legs.map((l) => l.key), ['Athens', 'Fira', 'Oia', 'Fira#2']);
    });

    test('one city in mixed case stays one run, keeping the first spelling', () {
      // The Go twin splits with strings.EqualFold; an exact compare here made a
      // rewritten "krakow" a second run beside "Krakow", so the city rendered
      // twice on the client only and legParityMismatches reported a leg-count
      // mismatch against the server payload.
      final legs = tripLegs([
        _item(0, city: 'Krakow'),
        _item(1, city: 'krakow'),
        _item(2, city: 'KRAKOW'),
      ]);

      expect(legs, hasLength(1));
      expect(legs.single.label, 'Krakow');
      expect(legs.single.items, hasLength(3));
    });

    test('the repeat counter folds case too, so a real revisit still gets #2',
        () {
      final legs = tripLegs([
        _item(0, city: 'Krakow'),
        _item(1, city: 'Prague'),
        _item(2, city: 'krakow'),
      ]);

      expect(legs.map((l) => l.label), ['Krakow', 'Prague', 'krakow']);
      expect(legs.map((l) => l.key), ['Krakow', 'Prague', 'krakow#2']);
    });

    test('coord is the first geocoded item; all-(0,0) runs have none', () {
      final legs = tripLegs([
        _item(0, city: 'Paris'), // manually added, ungeocoded
        _item(1, city: 'Paris', lat: 48.86, lng: 2.34),
        _item(2, city: 'Rome'),
      ]);

      expect(legs.first.coord, (lat: 48.86, lng: 2.34));
      expect(legs.last.coord, isNull);
    });

    test('empty input yields no legs', () {
      expect(tripLegs(const []), isEmpty);
    });
  });

  group('hub rule', () {
    test('hubOf prefers a non-blank dayTripFrom over the city', () {
      expect(
        hubOf(_item(0, city: 'Versailles', dayTripFrom: 'Paris')),
        'Paris',
      );
      expect(
        hubOf(_item(0, city: 'Versailles', dayTripFrom: '  ')),
        'Versailles',
      );
    });

    test('cityOf trims and falls back through blank cities', () {
      expect(cityOf(_item(0, city: '  ', address: 'Paris')), 'Paris');
      expect(cityOf(_item(0)), isNull);
    });

    test('cityFromAddress strips postal tokens and the country', () {
      expect(
        cityFromAddress('Av. da Índia 1, 1400-206 Lisboa, Portugal'),
        'Lisboa',
      );
      expect(cityFromAddress('Paris'), 'Paris');
      expect(cityFromAddress(null), isNull);
      expect(cityFromAddress(' , '), isNull);
    });
  });
}
