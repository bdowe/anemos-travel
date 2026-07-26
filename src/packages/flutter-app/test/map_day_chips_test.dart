import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/map_day_chips.dart';

import 'support/l10n_test_app.dart';

/// Hosts the strip at a fixed width, mirroring its real placement as a
/// Positioned row floating over a map.
Widget _host({
  required int dayCount,
  required int? selected,
  double width = 320,
  ValueChanged<int?>? onSelected,
}) {
  return localizedTestApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: MapDayChips(
            dayCount: dayCount,
            selected: selected,
            onSelected: onSelected ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

Rect _stripViewport(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byType(MapDayChips),
        matching: find.byType(SingleChildScrollView),
      ),
    );

Rect _chipRect(WidgetTester tester, String label) => tester.getRect(
      find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip)),
    );

void main() {
  testWidgets('every chip carries a >=44px hit box', (tester) async {
    await tester.pumpWidget(_host(dayCount: 2, selected: null, width: 600));
    await tester.pumpAndSettle();

    final chips = find.byType(ChoiceChip);
    expect(chips, findsNWidgets(3)); // All + Day 1 + Day 2
    for (var i = 0; i < 3; i++) {
      expect(
        tester.getSize(chips.at(i)).height,
        greaterThanOrEqualTo(44),
        reason: 'chip $i must meet the 44px touch minimum',
      );
    }
  });

  testWidgets('a tap outside the visual pill but inside the hit box selects', (
    tester,
  ) async {
    int? received = -1;
    await tester.pumpWidget(
      _host(
        dayCount: 2,
        selected: null,
        width: 600,
        onSelected: (v) => received = v,
      ),
    );
    await tester.pumpAndSettle();

    // 20px above center: within the 48px hit box, well above the compact
    // pill — exactly the kind of tap that used to pan the map instead.
    await tester.tapAt(
      tester.getCenter(find.text('Day 2')) + const Offset(0, -20),
    );
    expect(received, 2);
  });

  testWidgets('opening with a late day selected scrolls the strip to it', (
    tester,
  ) async {
    // Step 0 repro: a long trip opens the full-screen map on a late day and
    // the strip used to rest at Day 1 with the selection off-screen.
    await tester.pumpWidget(_host(dayCount: 10, selected: 9, width: 300));
    await tester.pumpAndSettle();

    final viewport = _stripViewport(tester);
    final chip = _chipRect(tester, 'Day 9');
    expect(chip.left, greaterThanOrEqualTo(viewport.left));
    expect(chip.right, lessThanOrEqualTo(viewport.right));
  });

  testWidgets('selection change scrolls the newly selected chip into view', (
    tester,
  ) async {
    await tester.pumpWidget(_host(dayCount: 10, selected: null, width: 300));
    await tester.pumpAndSettle();

    final viewport = _stripViewport(tester);
    // Sanity: Day 10 starts off-screen to the right.
    expect(_chipRect(tester, 'Day 10').right, greaterThan(viewport.right));

    await tester.pumpWidget(_host(dayCount: 10, selected: 10, width: 300));
    await tester.pumpAndSettle();

    final chip = _chipRect(tester, 'Day 10');
    expect(chip.left, greaterThanOrEqualTo(viewport.left));
    expect(chip.right, lessThanOrEqualTo(viewport.right));
  });
}
