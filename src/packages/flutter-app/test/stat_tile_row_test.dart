import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/stat_tile_row.dart';

/// StatTileRow contract (specs/trips-page-insights, restated by the trips-page
/// editorial redesign): a caption LINE of `value label` pairs — "12 trips ·
/// 284 travel days · 37 cities" — not the grid of equal-width tiles it was
/// until then. The pairs read left to right, a separator sits between them and
/// never before the first, and the weight is on the number.
///
/// The widget formats and pluralizes NOTHING — values arrive pre-formatted and
/// the l10n plural is resolved at the call site — so the assertions here are
/// "what was passed is what renders". Any stat count from zero to three must
/// lay out inside a phone-width column without overflowing.

/// Hosts the row at a fixed width; [width] narrows to the 360px phone floor
/// where three stats are tightest.
Widget _host(List<StatTileData> tiles, {double width = 400}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: StatTileRow(tiles: tiles)),
        ),
      ),
    );

void main() {
  testWidgets('renders every value beside its own label',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const [
      StatTileData(value: '12', label: 'Trips'),
      StatTileData(value: '284', label: 'Travel days'),
      StatTileData(value: '37', label: 'Cities'),
    ]));

    for (final text in ['12', 'Trips', '284', 'Travel days', '37', 'Cities']) {
      expect(find.text(text), findsOneWidget);
    }
    // Label beside its value and after it, sharing the line — the caption
    // form. Stacked tiles put the label BELOW, which is the shape this row
    // deliberately stopped being. Asserted as overlapping vertical extents
    // rather than equal tops: the two are baseline-aligned at different sizes,
    // so their boxes start at different y by design.
    final value = tester.getRect(find.text('12'));
    final label = tester.getRect(find.text('Trips'));
    expect(label.left, greaterThan(value.left));
    expect(label.top, lessThan(value.bottom));
    expect(value.top, lessThan(label.bottom));
    // ...and the next pair follows the previous one's label.
    expect(
      tester.getTopLeft(find.text('284')).dx,
      greaterThan(label.left),
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

  testWidgets('separators sit between stats, never before the first',
      (WidgetTester tester) async {
    // The dots are what make the line read as one caption instead of three
    // loose facts — and a line that opens with a dot reads as a fragment of
    // something above it.
    await tester.pumpWidget(_host(const [
      StatTileData(value: '1', label: 'Trip'),
      StatTileData(value: '284', label: 'Travel days'),
      StatTileData(value: '37', label: 'Cities'),
    ]));

    expect(find.text('·'), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('1')).dx,
      lessThan(tester.getTopLeft(find.text('·').first).dx),
    );

    // One stat is a caption of its own: nothing to separate.
    await tester.pumpWidget(
        _host(const [StatTileData(value: '1', label: 'Trip')]));
    expect(find.text('·'), findsNothing);
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
