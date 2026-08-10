import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finders that scope city-header date-chip assertions to ONE city's row.
///
/// The chip renders its range and nights suffix as two separate Text widgets
/// (shared-width columns), so a global `find.text('· 2 nights')` can be
/// satisfied by ANY city's chip — another leg with the same night count
/// aliases the assertion. Scoping through the header row is what pins the
/// PR #306 invariant that a range and its night count come from the SAME
/// visibleLegRanges pair.

/// The header Row for a city group — the nearest Row ancestor of its label
/// text. Reliable while the label text is unique on screen (it is for
/// collapsed groups, where item rows aren't built; expanded fixtures must
/// not name an item exactly like a city).
Finder headerRowOf(String cityLabel) =>
    find.ancestor(of: find.text(cityLabel), matching: find.byType(Row)).first;

/// A chip text inside one city's header row.
Finder chipTextIn(String cityLabel, String text) =>
    find.descendant(of: headerRowOf(cityLabel), matching: find.text(text));
