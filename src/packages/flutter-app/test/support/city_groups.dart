import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The label Text inside a CITY HEADER row — never the map strip's
/// same-name leg chip (specs/map-city-focus put the city names on the map
/// too). Scoped through the Rows that lead with the header's location pin
/// icon; the leg chips carry no icon.
Finder cityHeaderLabel(String label) => find.descendant(
      of: find.ancestor(
        of: find.byIcon(Icons.location_on),
        matching: find.byType(Row),
      ),
      matching: find.text(label),
    );

/// Toggles the trip-detail city group whose header shows [label] by tapping
/// it. Groups default to EXPANDED (expansion is list-only state, decoupled
/// from the map), so the first toggle collapses; tests that assert on a
/// collapsed group's behavior collapse it here first. [index] picks among
/// duplicate headers when a trip revisits a city (first run = 0).
Future<void> toggleCity(WidgetTester tester, String label,
    {int index = 0}) async {
  await tester.tap(cityHeaderLabel(label).at(index));
  await tester.pumpAndSettle();
}

/// Collapse-intent alias of [toggleCity] for call sites where the direction
/// matters to the reader; the tap itself is the same list-only toggle.
Future<void> collapseCity(WidgetTester tester, String label,
        {int index = 0}) =>
    toggleCity(tester, label, index: index);
