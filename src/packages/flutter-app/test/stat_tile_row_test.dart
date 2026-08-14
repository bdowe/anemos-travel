import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/stat_tile_row.dart';

/// StatTileRow contract (specs/trips-page-insights): equal-width tiles of a
/// pre-formatted value over a caller-supplied label. The widget formats and
/// pluralizes NOTHING — values arrive pre-formatted and the l10n plural is
/// resolved at the call site — so the assertions here are "what was passed is
/// what renders". Any tile count from zero to three must lay out inside a
/// phone-width column without overflowing.

/// Hosts the row at a fixed width; [width] narrows to the 360px phone floor
/// where three tiles are tightest.
Widget _host(List<StatTileData> tiles, {double width = 400}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: StatTileRow(tiles: tiles)),
        ),
      ),
    );

void main() {
  testWidgets('renders every tile value over its label',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const [
      StatTileData(value: '12', label: 'Trips'),
      StatTileData(value: '284', label: 'Travel days'),
      StatTileData(value: '37', label: 'Cities'),
    ]));

    for (final text in ['12', 'Trips', '284', 'Travel days', '37', 'Cities']) {
      expect(find.text(text), findsOneWidget);
    }
    // Value above label, not beside it.
    expect(
      tester.getTopLeft(find.text('12')).dy,
      lessThan(tester.getTopLeft(find.text('Trips')).dy),
    );
  });

  testWidgets('prints the label it is handed — singular at 1, plural at N',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const [
      StatTileData(value: '1', label: 'Trip'),
      StatTileData(value: '5', label: 'Cities'),
    ]));

    expect(find.text('Trip'), findsOneWidget);
    // The widget never derives the plural from the value.
    expect(find.text('Trips'), findsNothing);
    expect(find.text('Cities'), findsOneWidget);
  });

  testWidgets('tiles share the width equally', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const [
      StatTileData(value: '1', label: 'Trip'),
      StatTileData(value: '284', label: 'Travel days'),
      StatTileData(value: '37', label: 'Cities'),
    ]));

    final widths = tester
        .widgetList<Column>(find.descendant(
            of: find.byType(StatTileRow), matching: find.byType(Column)))
        .map((c) => tester.getSize(find.byWidget(c)).width)
        .toSet();
    expect(widths, hasLength(1));
  });

  testWidgets('empty, single, and three-tile rows all lay out without overflow',
      (WidgetTester tester) async {
    // An overflowing Row throws in tests, so an exception-free pump at the
    // 360px phone floor IS the assertion. Zero tiles is a real case: the
    // caller drops zero-valued segments.
    for (final tiles in const [
      <StatTileData>[],
      [StatTileData(value: '1', label: 'Trip')],
      [
        StatTileData(value: '12', label: 'Trips'),
        StatTileData(value: '284', label: 'Travel days'),
        StatTileData(value: '37', label: 'Cities'),
      ],
    ]) {
      await tester.pumpWidget(_host(tiles, width: 360));
      expect(tester.takeException(), isNull);
    }
    expect(find.byType(StatTileRow), findsOneWidget);
  });

  testWidgets('a label too long for its share ellipsizes, never overflows',
      (WidgetTester tester) async {
    // The es strings run long; one over-wide tile must truncate rather than
    // push its neighbours out of the row.
    await tester.pumpWidget(_host(const [
      StatTileData(value: '284', label: 'Días de viaje'),
      StatTileData(value: '37', label: 'Ciudades visitadas'),
      StatTileData(value: '12', label: 'Viajes'),
    ], width: 300));

    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(find.text('Ciudades visitadas'));
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);
  });
}
