import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/utils/leg_ranges.dart';
import 'package:travel_route_planner/utils/trip_legs.dart';
import 'package:travel_route_planner/widgets/trip_map_destinations.dart';

/// The map strip's label rule (specs/map-city-focus): a trip that revisits a
/// city yields two runs with the SAME label, and two identical chips can't say
/// which stay a tap will focus. Only repeated labels get a qualifier.

TripLeg _leg(String key, String label) => (
      key: key,
      label: label,
      locality: label == kOtherPlacesLabel ? null : label,
      items: const <ItineraryItem>[],
      coord: null,
    );

LegRange _range(String label, DateTime? start) => (
      label: label,
      start: start,
      end: start,
      coord: null,
      stayAnchored: false,
      itemDerived: true,
    );

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('a trip with no repeats carries no qualifiers', () {
    final legs = [_leg('Athens', 'Athens'), _leg('Naxos', 'Naxos')];
    final entries = mapLegChipEntries(l10n, legs, [
      _range('Athens', DateTime(2026, 9, 1)),
      _range('Naxos', DateTime(2026, 9, 5)),
    ]);

    expect(entries.map((e) => e.label), ['Athens', 'Naxos']);
    expect(entries.every((e) => e.qualifier == null), isTrue,
        reason: 'the ordinary trip keeps bare city names');
  });

  test('a revisited city is qualified by its start date; neighbours are not',
      () {
    final legs = [
      _leg('Fira', 'Fira'),
      _leg('Naxos', 'Naxos'),
      _leg('Fira#2', 'Fira'),
    ];
    final entries = mapLegChipEntries(l10n, legs, [
      _range('Fira', DateTime(2026, 9, 3)),
      _range('Naxos', DateTime(2026, 9, 5)),
      _range('Fira', DateTime(2026, 9, 9)),
    ]);

    expect(entries[0].qualifier, 'Sep 3');
    expect(entries[2].qualifier, 'Sep 9');
    expect(entries[1].qualifier, isNull);
    // The city stays bare: `tripNoPlacesInLeg` speaks this in a sentence.
    expect(entries.map((e) => e.label), ['Fira', 'Naxos', 'Fira']);
    // Keys still address the runs independently.
    expect(entries.map((e) => e.key), ['Fira', 'Naxos', 'Fira#2']);
  });

  test('an undated trip falls back to visit numbers', () {
    final legs = [_leg('Fira', 'Fira'), _leg('Fira#2', 'Fira')];
    final entries = mapLegChipEntries(
        l10n, legs, [_range('Fira', null), _range('Fira', null)]);

    expect(entries.map((e) => e.qualifier), ['Visit 1', 'Visit 2']);
  });

  test('two runs collapsed onto one day fall back to visit numbers', () {
    // Dense itineraries can allocate both runs the same day — a date that
    // repeats disambiguates nothing, so it must not be shown as if it did.
    final legs = [_leg('Fira', 'Fira'), _leg('Fira#2', 'Fira')];
    final day = DateTime(2026, 9, 3);
    final entries = mapLegChipEntries(
        l10n, legs, [_range('Fira', day), _range('Fira', day)]);

    expect(entries.map((e) => e.qualifier), ['Visit 1', 'Visit 2']);
  });

  test('a partially dated repeat set falls back rather than mixing', () {
    final legs = [_leg('Fira', 'Fira'), _leg('Fira#2', 'Fira')];
    final entries = mapLegChipEntries(l10n, legs,
        [_range('Fira', DateTime(2026, 9, 3)), _range('Fira', null)]);

    expect(entries.map((e) => e.qualifier), ['Visit 1', 'Visit 2'],
        reason: 'one dated chip beside one numbered chip reads as two rules');
  });

  test('three visits all get qualified', () {
    final legs = [
      _leg('Fira', 'Fira'),
      _leg('Fira#2', 'Fira'),
      _leg('Fira#3', 'Fira'),
    ];
    final entries = mapLegChipEntries(l10n, legs, [
      _range('Fira', DateTime(2026, 9, 1)),
      _range('Fira', DateTime(2026, 9, 5)),
      _range('Fira', DateTime(2026, 9, 9)),
    ]);

    expect(entries.map((e) => e.qualifier), ['Sep 1', 'Sep 5', 'Sep 9']);
  });

  test('the Other places run is localized, and qualifies like any label', () {
    final legs = [
      _leg('Other places', kOtherPlacesLabel),
      _leg('Naxos', 'Naxos'),
      _leg('Other places#2', kOtherPlacesLabel),
    ];
    final entries = mapLegChipEntries(l10n, legs, [
      _range(kOtherPlacesLabel, DateTime(2026, 9, 1)),
      _range('Naxos', DateTime(2026, 9, 5)),
      _range(kOtherPlacesLabel, DateTime(2026, 9, 9)),
    ]);

    expect(entries[0].label, l10n.tripOtherPlaces);
    expect(entries[0].qualifier, 'Sep 1');
    expect(entries[2].qualifier, 'Sep 9');
  });

  test('labelText overrides the Other-places wording (the shared view)', () {
    // The shared view calls that run "Places" in its own section headers; a
    // chip saying "Other places" above a header saying "Places" is the bug
    // this hook exists to prevent.
    final legs = [_leg('Other places', kOtherPlacesLabel)];
    final entries = mapLegChipEntries(
      l10n,
      legs,
      [_range(kOtherPlacesLabel, DateTime(2026, 9, 1))],
      labelText: (l, label) =>
          label == kOtherPlacesLabel ? l.sharedPlacesGroup : label,
    );

    expect(entries.single.label, l10n.sharedPlacesGroup);
    expect(entries.single.label, isNot(l10n.tripOtherPlaces));
  });
}
