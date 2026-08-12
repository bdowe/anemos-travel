import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/map_leg_chips.dart';

import 'support/l10n_test_app.dart';

List<({String key, String label})> _cities(int n) => [
      for (var i = 1; i <= n; i++) (key: 'City $i', label: 'City $i'),
    ];

/// Hosts the strip at a fixed width, mirroring its real placement as a
/// Positioned row floating over a map.
Widget _host({
  required List<({String key, String label})> legs,
  required String? selected,
  double width = 320,
  ValueChanged<String?>? onSelected,
  Set<String>? mappedLegKeys,
}) {
  return localizedTestApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: MapLegChips(
            legs: legs,
            selected: selected,
            onSelected: onSelected ?? (_) {},
            mappedLegKeys: mappedLegKeys,
          ),
        ),
      ),
    ),
  );
}

Rect _stripViewport(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byType(MapLegChips),
        matching: find.byType(SingleChildScrollView),
      ),
    );

Rect _chipRect(WidgetTester tester, String label) => tester.getRect(
      find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip)),
    );

void main() {
  testWidgets('every chip carries a >=44px hit box', (tester) async {
    await tester
        .pumpWidget(_host(legs: _cities(2), selected: null, width: 600));
    await tester.pumpAndSettle();

    final chips = find.byType(ChoiceChip);
    expect(chips, findsNWidgets(3)); // All + City 1 + City 2
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
    String? received = 'sentinel';
    await tester.pumpWidget(
      _host(
        legs: _cities(2),
        selected: null,
        width: 600,
        onSelected: (v) => received = v,
      ),
    );
    await tester.pumpAndSettle();

    // 20px above center: within the 48px hit box, well above the compact
    // pill — exactly the kind of tap that used to pan the map instead.
    await tester.tapAt(
      tester.getCenter(find.text('City 2')) + const Offset(0, -20),
    );
    expect(received, 'City 2');
  });

  testWidgets('the All chip reports null', (tester) async {
    String? received = 'sentinel';
    await tester.pumpWidget(
      _host(
        legs: _cities(2),
        selected: 'City 1',
        width: 600,
        onSelected: (v) => received = v,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('All'));
    expect(received, isNull);
  });

  testWidgets('renders nothing with fewer than 2 legs', (tester) async {
    await tester.pumpWidget(_host(legs: _cities(1), selected: null));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);

    await tester.pumpWidget(_host(legs: const [], selected: null));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('unmapped legs render muted but stay tappable', (tester) async {
    String? received;
    await tester.pumpWidget(
      _host(
        legs: _cities(3),
        selected: null,
        width: 600,
        mappedLegKeys: {'City 1', 'City 3'},
        onSelected: (v) => received = v,
      ),
    );
    await tester.pumpAndSettle();

    Color? labelColor(String label) => tester
        .widget<ChoiceChip>(
          find.ancestor(
              of: find.text(label), matching: find.byType(ChoiceChip)),
        )
        .labelStyle
        ?.color;
    expect(labelColor('City 2'), Colors.white60);
    expect(labelColor('City 1'), Colors.white);

    await tester.tap(find.text('City 2'));
    expect(received, 'City 2');
  });

  testWidgets('revisited city: same-label chips select by their own key', (
    tester,
  ) async {
    String? received;
    await tester.pumpWidget(
      _host(
        legs: const [
          (key: 'Paris', label: 'Paris'),
          (key: 'Rome', label: 'Rome'),
          (key: 'Paris#2', label: 'Paris'),
        ],
        selected: null,
        width: 600,
        onSelected: (v) => received = v,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paris').at(1));
    expect(received, 'Paris#2');
    await tester.tap(find.text('Paris').at(0));
    expect(received, 'Paris');
  });

  testWidgets('opening with a late leg selected scrolls the strip to it', (
    tester,
  ) async {
    // A long trip opens the full-screen map with a late leg preselected and
    // the strip must not rest at the left with the selection off-screen.
    await tester.pumpWidget(
        _host(legs: _cities(10), selected: 'City 9', width: 300));
    await tester.pumpAndSettle();

    final viewport = _stripViewport(tester);
    final chip = _chipRect(tester, 'City 9');
    expect(chip.left, greaterThanOrEqualTo(viewport.left));
    expect(chip.right, lessThanOrEqualTo(viewport.right));
  });

  testWidgets('selection change scrolls the newly selected chip into view', (
    tester,
  ) async {
    await tester
        .pumpWidget(_host(legs: _cities(10), selected: null, width: 300));
    await tester.pumpAndSettle();

    final viewport = _stripViewport(tester);
    // Sanity: City 10 starts off-screen to the right.
    expect(_chipRect(tester, 'City 10').right, greaterThan(viewport.right));

    await tester
        .pumpWidget(_host(legs: _cities(10), selected: 'City 10', width: 300));
    await tester.pumpAndSettle();

    final chip = _chipRect(tester, 'City 10');
    expect(chip.left, greaterThanOrEqualTo(viewport.left));
    expect(chip.right, lessThanOrEqualTo(viewport.right));
  });
}
