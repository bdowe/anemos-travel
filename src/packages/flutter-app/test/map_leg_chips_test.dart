import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/app_map.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';

import 'support/l10n_test_app.dart';

List<({String key, String label, String? qualifier})> _cities(int n) => [
      for (var i = 1; i <= n; i++)
        (key: 'City $i', label: 'City $i', qualifier: null),
    ];

/// Hosts the strip at a fixed width, mirroring its real placement as a
/// Positioned row floating over a map.
Widget _host({
  required List<({String key, String label, String? qualifier})> legs,
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

/// The way back to the whole-trip overview — a [MapControlButton], not a chip,
/// so it can never be mistaken for a destination.
final Finder _reset = find.descendant(
  of: find.byType(MapLegChips),
  matching: find.byType(MapControlButton),
);

void main() {
  testWidgets('every chip carries a >=44px hit box', (tester) async {
    await tester
        .pumpWidget(_host(legs: _cities(2), selected: null, width: 600));
    await tester.pumpAndSettle();

    final chips = find.byType(ChoiceChip);
    // One chip per leg and nothing else: the overview is not a destination,
    // so it does not get a chip.
    expect(chips, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
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

  testWidgets('no reset control until a leg is focused', (tester) async {
    await tester
        .pumpWidget(_host(legs: _cities(3), selected: null, width: 600));
    await tester.pumpAndSettle();
    expect(_reset, findsNothing);

    await tester
        .pumpWidget(_host(legs: _cities(3), selected: 'City 2', width: 600));
    await tester.pumpAndSettle();
    expect(_reset, findsOneWidget);
  });

  testWidgets('the reset control reports null', (tester) async {
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

    await tester.tap(_reset);
    expect(received, isNull);
  });

  testWidgets('the reset is not a second close ✕', (tester) async {
    // The full-screen map puts a CloseButton at top-left, directly above this
    // slot; a ✕ here rendered as the same control twice, 40px apart, one
    // closing the map and one clearing the focus. Icons.zoom_out_map is out
    // too — the bottom-right column's "Reset map" is Icons.zoom_in_map and
    // refits the camera without changing what is shown.
    await tester
        .pumpWidget(_host(legs: _cities(2), selected: 'City 1', width: 600));
    await tester.pumpAndSettle();

    final icon = tester.widget<MapControlButton>(_reset).icon;
    expect(icon, isNot(Icons.close));
    expect(icon, isNot(Icons.zoom_out_map));
    expect(icon, isNot(Icons.zoom_in_map));
  });

  testWidgets('the reset control carries a >=44px hit box', (tester) async {
    await tester
        .pumpWidget(_host(legs: _cities(2), selected: 'City 1', width: 600));
    await tester.pumpAndSettle();

    final size = tester.getSize(_reset);
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('the reset stays put while the chip strip scrolls', (
    tester,
  ) async {
    // The exit is pinned outside the scroll view: on a long trip the strip
    // scrolls, and an exit that can scroll off-screen is not an exit.
    await tester
        .pumpWidget(_host(legs: _cities(10), selected: 'City 1', width: 300));
    await tester.pumpAndSettle();

    final before = tester.getRect(_reset);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();

    expect(_stripViewport(tester).left, greaterThan(before.right - 1),
        reason: 'the strip must start after the reset, not under it');
    expect(tester.getRect(_reset), before);
  });

  testWidgets('focusing a leg never moves the chip strip sideways', (
    tester,
  ) async {
    // The reset's space is reserved, not grown into: a slot that appeared
    // would shove every chip 44px right on each tap, and would land the
    // preselected chip outside the strip because _revealSelected measures the
    // viewport mid-resize.
    await tester
        .pumpWidget(_host(legs: _cities(3), selected: null, width: 600));
    await tester.pumpAndSettle();
    final resting = _stripViewport(tester);

    await tester
        .pumpWidget(_host(legs: _cities(3), selected: 'City 2', width: 600));
    await tester.pumpAndSettle();
    expect(_stripViewport(tester), resting);
  });

  testWidgets('focusing a leg does not deepen the map overlay band', (
    tester,
  ) async {
    // mapTopInset is what keeps fitted markers clear of this row; the reset
    // button is shorter than the chips, so appearing must not grow it.
    await tester
        .pumpWidget(_host(legs: _cities(3), selected: null, width: 600));
    await tester.pumpAndSettle();
    final resting = tester.getSize(find.byType(MapLegChips)).height;

    await tester
        .pumpWidget(_host(legs: _cities(3), selected: 'City 2', width: 600));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MapLegChips)).height, resting);

    // 8px offset above + the row + 8px clearance below.
    expect(8 + resting + 8, lessThanOrEqualTo(MapLegChips.mapTopInset));
  });

  testWidgets('renders nothing with fewer than 2 legs', (tester) async {
    await tester.pumpWidget(_host(legs: _cities(1), selected: null));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(_reset, findsNothing);

    // Even carrying a focus: a one-leg trip has no overview to return to.
    await tester.pumpWidget(_host(legs: _cities(1), selected: 'City 1'));
    await tester.pumpAndSettle();
    expect(_reset, findsNothing);

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
          (key: 'Paris', label: 'Paris', qualifier: 'Sep 3'),
          (key: 'Rome', label: 'Rome', qualifier: null),
          (key: 'Paris#2', label: 'Paris', qualifier: 'Sep 9'),
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

  testWidgets('a qualifier renders beside its city and only where given', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        legs: const [
          (key: 'Paris', label: 'Paris', qualifier: 'Sep 3'),
          (key: 'Rome', label: 'Rome', qualifier: null),
          (key: 'Paris#2', label: 'Paris', qualifier: 'Sep 9'),
        ],
        selected: null,
        width: 600,
      ),
    );
    await tester.pumpAndSettle();

    // The city stays its own Text so callers that speak it in a sentence
    // (tripNoPlacesInLeg) keep a bare label; the qualifier rides alongside.
    expect(find.text('Paris'), findsNWidgets(2));
    expect(find.text(' · Sep 3'), findsOneWidget);
    expect(find.text(' · Sep 9'), findsOneWidget);
    // Rome is unique, so it carries nothing extra.
    expect(
      find.descendant(
        of: find.ancestor(
            of: find.text('Rome'), matching: find.byType(ChoiceChip)),
        matching: find.byType(Text),
      ),
      findsOneWidget,
    );
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

    // Sanity: City 10 starts off-screen to the right.
    expect(
      _chipRect(tester, 'City 10').right,
      greaterThan(_stripViewport(tester).right),
    );

    await tester
        .pumpWidget(_host(legs: _cities(10), selected: 'City 10', width: 300));
    await tester.pumpAndSettle();

    final viewport = _stripViewport(tester);
    final chip = _chipRect(tester, 'City 10');
    expect(chip.left, greaterThanOrEqualTo(viewport.left));
    expect(chip.right, lessThanOrEqualTo(viewport.right));
  });
}
