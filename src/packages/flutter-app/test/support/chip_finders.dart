import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/app_map.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';

import 'city_groups.dart';

/// Finders that scope city-header date-chip assertions to ONE city's row.
///
/// The chip renders its range and nights suffix as two separate Text widgets
/// (shared-width columns), so a global `find.text('· 2 nights')` can be
/// satisfied by ANY city's chip — another leg with the same night count
/// aliases the assertion. Scoping through the header row is what pins the
/// PR #306 invariant that a range and its night count come from the SAME
/// visibleLegRanges pair.

/// The header Row for a city group — the nearest Row ancestor of its label
/// text, resolved via [cityHeaderLabel] so the map strip's same-name leg
/// chip can never alias it. Expanded fixtures must still not name an item
/// exactly like a city.
Finder headerRowOf(String cityLabel) => find
    .ancestor(of: cityHeaderLabel(cityLabel), matching: find.byType(Row))
    .first;

/// A chip text inside one city's header row.
Finder chipTextIn(String cityLabel, String text) =>
    find.descendant(of: headerRowOf(cityLabel), matching: find.text(text));

/// The map strip's reset — the globe that returns a focused map to the
/// whole-trip overview. It is a [MapControlButton], not a chip: the overview is
/// the
/// absence of a destination choice, so it is deliberately not rendered in the
/// destinations' visual language (it replaced the old "All" chip). Present
/// only while a leg is focused, so `findsNothing` is the resting assertion.
Finder get mapResetButton => find.descendant(
      of: find.byType(MapLegChips),
      matching: find.byType(MapControlButton),
    );

/// Taps the map strip's reset and settles the camera re-fit behind it.
Future<void> tapMapReset(WidgetTester tester) async {
  await tester.tap(mapResetButton);
  await tester.pumpAndSettle();
}
