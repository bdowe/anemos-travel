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

/// Expands the trip-detail city group whose header shows [label] by tapping
/// it. Groups default to collapsed (only a sole group is seeded open), so
/// tests that assert on a group's contents expand it first. [index] picks
/// among duplicate headers when a trip revisits a city (first run = 0).
Future<void> expandCity(WidgetTester tester, String label,
    {int index = 0}) async {
  await tester.tap(cityHeaderLabel(label).at(index));
  await tester.pumpAndSettle();
}
