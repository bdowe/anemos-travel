import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/utils/leg_ranges.dart';

// CROSS-LANGUAGE CONTRACT (specs/trip-dates-truth): these fixtures and
// expected values are hand-mirrored in the Go twin suite
// (api/trip_render_legs_test.go, stage 0b) — same trips, same expected
// spans, city names and all. Pinning both sides to the same literals means a
// drift on either side fails a test instead of shipping silently (the
// calendar-title parity convention). Divergences that are DELIBERATE are
// marked "diverges:" below with the decision.

ItineraryItem _item(int pos, String name, String? city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: city == null ? null : '$city address',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip(
  List<ItineraryItem> items, {
  String? startDate,
  String? endDate,
  List<Accommodation>? stays,
}) =>
    Trip(
      id: 't1',
      title: 'Fixture',
      startDate: startDate,
      endDate: endDate,
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items,
      accommodations: stays,
    );

DateTime _d(String iso) => DateTime.parse(iso);

void main() {
  group('rawLegRanges', () {
    test('item-day ranges anchored to the trip start', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
          _item(1, 'Liseberg', 'Gothenburg', day: 3),
          _item(2, 'Prado', 'Madrid', day: 5),
        ],
        startDate: '2026-08-24',
        endDate: '2026-08-28',
      ));
      expect(ranges.length, 2);
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-26'));
      // Madrid's raw range collapses to its single item day — the visible
      // pass, not this one, pulls its start back to the arrival.
      expect(ranges[1].start, _d('2026-08-28'));
      expect(ranges[1].end, _d('2026-08-28'));
      expect(ranges[1].stayAnchored, isFalse);
    });

    test('first leg anchors to the trip start when items sit late', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Prague', 'Prague', day: 4),
          _item(1, 'Kraków', 'Kraków', day: 9),
        ],
        startDate: '2026-08-24',
        endDate: '2026-09-01',
      ));
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-27'));
    });

    test('a confirmed stay overrides item days and sets stayAnchored', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Quito', 'Quito', day: 5),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Quito',
            address: 'Av. González Suárez, Quito, Ecuador',
            checkIn: '2026-09-03',
            checkOut: '2026-09-05',
          ),
        ],
      ));
      expect(ranges[1].start, _d('2026-09-03'));
      expect(ranges[1].end, _d('2026-09-05'));
      expect(ranges[1].stayAnchored, isTrue);
    });

    // diverges: stay matching is address-only client-side today; the Go twin
    // also matches by NAME (agent-added stays carry no address). The unified
    // rule after the payload cutover is address-then-name — this pin
    // documents the pre-cutover client behavior.
    test('an address-less stay does not anchor (client rule, pre-cutover)',
        () {
      final ranges = rawLegRanges(_trip(
        [_item(0, 'Quito', 'Quito', day: 3)],
        startDate: '2026-09-01',
        endDate: '2026-09-05',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Stay in Quito',
            checkIn: '2026-09-02',
            checkOut: '2026-09-04',
          ),
        ],
      ));
      expect(ranges[0].stayAnchored, isFalse);
      // First-leg anchor applies instead: start = trip start.
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-03'));
    });

    test('undated legs take the weighted auto-allocation slice', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris'),
          _item(1, 'Orsay', 'Paris'),
          _item(2, 'Marais walk', 'Paris'),
          _item(3, 'Colosseum', 'Rome'),
        ],
        startDate: '2026-06-01',
        endDate: '2026-06-08', // 8 days: Paris (3 items) 6, Rome (1 item) 2
      ));
      expect(ranges[0].start, _d('2026-06-01'));
      expect(ranges[0].end, _d('2026-06-06'));
      expect(ranges[1].start, _d('2026-06-07'));
      expect(ranges[1].end, _d('2026-06-08'));
    });

    test('more locations than days maps each to one ascending day', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'A', 'Alpha'),
          _item(1, 'B', 'Beta'),
          _item(2, 'C', 'Gamma'),
        ],
        startDate: '2026-06-01',
        endDate: '2026-06-02', // 2 days, 3 cities
      ));
      expect(ranges[0].start, _d('2026-06-01'));
      expect(ranges[1].start, _d('2026-06-01'));
      expect(ranges[2].start, _d('2026-06-02'));
      for (final r in ranges) {
        expect(r.start, r.end);
      }
    });

    test('a dateless trip yields null ranges', () {
      final ranges = rawLegRanges(_trip(
        [_item(0, 'Louvre', 'Paris', day: 1)],
      ));
      expect(ranges.single.start, isNull);
      expect(ranges.single.end, isNull);
    });
  });

  group('visibleLegRanges', () {
    test('arrival pulls a late-starting leg back to the previous end', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
          _item(1, 'Liseberg', 'Gothenburg', day: 3),
          _item(2, 'Prado', 'Madrid', day: 5),
        ],
        startDate: '2026-08-24',
        endDate: '2026-08-28',
      ));
      expect(ranges[1].start, _d('2026-08-26'));
      expect(ranges[1].end, _d('2026-08-28'));
    });

    test('a squeezed leg collapses to a zero-night stop and cascades', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 5),
          _item(3, 'Mitad del Mundo', 'Galápagos', day: 6),
          _item(4, 'Tortuga Bay', 'Galápagos', day: 7),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
      ));
      expect(ranges[1].start, _d('2026-09-06'));
      expect(ranges[1].end, _d('2026-09-06'));
      expect(ranges[2].start, _d('2026-09-06'));
      expect(ranges[2].end, _d('2026-09-07'));
    });

    test('consecutive squeezed legs chain onto the same arrival', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 4),
          _item(3, 'Guayaquil', 'Guayaquil', day: 5),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
      ));
      expect(ranges[1].start, _d('2026-09-06'));
      expect(ranges[1].end, _d('2026-09-06'));
      expect(ranges[2].start, _d('2026-09-06'));
      expect(ranges[2].end, _d('2026-09-06'));
    });

    // The mirror of the first-leg anchor: the planner leaves the day home
    // empty (it's a travel day), so the last leg's item-derived end falls
    // short of the trip's own end date. Amsterdam must still read
    // Aug 21 – Aug 25 · 4 nights, not Aug 21 – Aug 24.
    test('the last leg runs through the trip end when its day home is empty',
        () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris', day: 1),
          _item(1, "Musée d'Orsay", 'Paris', day: 2),
          _item(2, 'Rijksmuseum', 'Amsterdam', day: 4),
          _item(3, 'Anne Frank House', 'Amsterdam', day: 5),
          // Day 6 (Aug 25) is the journey home and carries nothing.
        ],
        startDate: '2026-08-20',
        endDate: '2026-08-25',
      ));
      expect(ranges[0].start, _d('2026-08-20'));
      expect(ranges[0].end, _d('2026-08-21'));
      expect(ranges[1].start, _d('2026-08-21'));
      expect(ranges[1].end, _d('2026-08-25'));
    });

    // A confirmed stay's checkout is explicit, so it is never stretched — the
    // same carve-out the first-leg anchor makes for check-in. The START is the
    // arrival (Paris's visible end), the pre-existing chain rule.
    test('the last-leg anchor leaves a confirmed stay alone', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris', day: 1),
          _item(1, 'Rijksmuseum', 'Amsterdam', day: 4),
        ],
        startDate: '2026-08-20',
        endDate: '2026-08-25',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Pulitzer',
            address: 'Prinsengracht, Amsterdam',
            checkIn: '2026-08-23',
            checkOut: '2026-08-24',
          ),
        ],
      ));
      expect(ranges[1].start, _d('2026-08-20'));
      expect(ranges[1].end, _d('2026-08-24'));
    });

    // A leg the chain squeezed to a zero-night stop is an interim overrun
    // state. Stretching it to the trip's end would invent the very nights the
    // squeeze says are gone. (The 'consecutive squeezed legs' case above pins
    // the same guard from the other direction — Guayaquil stays Sep 6/Sep 6 on
    // a trip that runs to Sep 7.)
    test('the last-leg anchor leaves a collapsed leg alone', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 4),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
      ));
      expect(ranges[1].start, _d('2026-09-06'));
      expect(ranges[1].end, _d('2026-09-06'));
    });

    test('a confirmed stay is never collapsed', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 5),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Quito',
            address: 'Av. González Suárez, Quito, Ecuador',
            checkIn: '2026-09-03',
            checkOut: '2026-09-05',
          ),
        ],
      ));
      expect(ranges[1].start, _d('2026-09-03'));
      expect(ranges[1].end, _d('2026-09-05'));
    });

    // diverges: client-side a null-range leg still participates in the chain
    // (prevEnd is overwritten with null, disabling adjustment downstream);
    // the Go twin SKIPS undated legs without touching prevEnd. The unified
    // payload rule is the Go one; this pin documents the pre-cutover client
    // behavior so the cutover diff is deliberate.
    test('a dateless interior leg resets the chain (client rule, pre-cutover)',
        () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'A', 'Alpha', day: 1),
          _item(1, 'mystery', null),
          _item(2, 'C', 'Gamma', day: 5),
        ],
        startDate: '2026-06-01',
        // No end date: no auto-allocation, so the hubless leg has null range.
      ));
      expect(ranges.length, 3);
      expect(ranges[1].start, _d('2026-06-01')); // adopts prev end...
      expect(ranges[1].end, isNull); // ...but its own end is null
      // Chain reset: Gamma keeps its raw start, un-adjusted.
      expect(ranges[2].start, _d('2026-06-05'));
    });
  });

  group('allocateDays', () {
    test('splits by weight with largest-remainder distribution', () {
      expect(allocateDays(8, [3, 1]), [6, 2]);
      expect(allocateDays(10, [1, 1, 1]), [4, 3, 3]);
    });

    test('floors at one day each and handles totalDays <= n', () {
      expect(allocateDays(2, [5, 5, 5]), [1, 1, 1]);
    });
  });

  // nightsBetween is a client-display helper only — deliberately NOT part of
  // the hand-mirrored Go-twin contract above; the legs payload carries no
  // nights field.
  group('nightsBetween', () {
    test('checkout-exclusive whole nights', () {
      expect(nightsBetween(DateTime(2026, 8, 24), DateTime(2026, 8, 27)), 3);
      expect(nightsBetween(DateTime(2026, 8, 27), DateTime(2026, 9, 1)), 5);
    });

    test('same day is zero nights', () {
      expect(nightsBetween(DateTime(2026, 9, 6), DateTime(2026, 9, 6)), 0);
    });

    test('DST spring-forward does not drop a night', () {
      // US DST starts Mar 8 2026; a raw local-midnight Duration diff reads
      // ~1.96 days and would truncate to 1.
      expect(nightsBetween(DateTime(2026, 3, 7), DateTime(2026, 3, 9)), 2);
    });
  });

  // MIRRORED from api/trip_render_legs_test.go (the calendar-parity
  // convention): same trip, same cities, same expected spans. Change either
  // side and you must change both.
  group('a spine itinerary (specs/shape-before-schedule)', () {
    // Two places a city — one on the day the traveler arrives, one on the day
    // they move on — except the last city, whose move-on day is the journey
    // home. Days 2-3, 5 and 7 carry nothing.
    Trip spine() => _trip(
          [
            _item(0, 'Time Out Market', 'Lisbon', day: 1),
            _item(1, 'Pastéis de Belém', 'Lisbon', day: 4),
            _item(2, 'Livraria Lello', 'Porto', day: 4),
            _item(3, 'Cais da Ribeira', 'Porto', day: 6),
            _item(4, 'Museo del Prado', 'Madrid', day: 6),
          ],
          startDate: '2026-09-01',
          endDate: '2026-09-08',
        );

    test('renders the same ranges a dense itinerary would', () {
      final ranges = visibleLegRanges(spine());
      expect(ranges.length, 3);
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-04'));
      expect(ranges[1].start, _d('2026-09-04'));
      expect(ranges[1].end, _d('2026-09-06'));
      // The last-leg anchor carries Madrid through the trip's end; its own
      // items stop on the day it was reached.
      expect(ranges[2].start, _d('2026-09-06'));
      expect(ranges[2].end, _d('2026-09-08'));
    });

    test('a one-city spine is one arrival place stretched by the trip end', () {
      final ranges = visibleLegRanges(_trip(
        [_item(0, 'Museo del Prado', 'Madrid', day: 1)],
        startDate: '2026-09-01',
        endDate: '2026-09-08',
      ));
      expect(ranges.single.start, _d('2026-09-01'));
      expect(ranges.single.end, _d('2026-09-08'));
    });

    // CHARACTERIZATION — the WRONG output, pinned on purpose. It is the failure
    // the planner's "the move-on place is NOT optional" rule and the tool
    // result's warning line exist to prevent. With only arrival anchors the
    // chain pulls each leg's start back to the previous leg's single item day,
    // so every city's nights land on the city after it.
    test('arrival anchors alone collapse every leg but the last', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Time Out Market', 'Lisbon', day: 1),
          _item(1, 'Livraria Lello', 'Porto', day: 4),
          _item(2, 'Museo del Prado', 'Madrid', day: 6),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-08',
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-01')); // three nights gone
      expect(ranges[1].start, _d('2026-09-01'));
      expect(ranges[1].end, _d('2026-09-04'));
      expect(ranges[2].start, _d('2026-09-04'));
      expect(ranges[2].end, _d('2026-09-08'));
    });
  });
}
