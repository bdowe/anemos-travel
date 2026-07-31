import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/utils/geolocation_stub.dart';
import 'package:travel_route_planner/utils/geolocation_types.dart';
import 'package:travel_route_planner/widgets/near_me_chip.dart';

import 'support/l10n_test_app.dart';

/// "What's near me?" chip. VM tests resolve the conditional import to the
/// non-web stub (GeoErrorKind.unsupported), which is exactly the fallback
/// branch: no fix → manual location dialog → natural-language message with no
/// displayLabel (the geolocation branch's label/coordinates contract is
/// covered by the stub test + the widget's send wiring being shared).
void main() {
  test('non-web geolocation stub reports unsupported', () async {
    final r = await getCurrentPosition();
    expect(r.ok, isFalse);
    expect(r.error, GeoErrorKind.unsupported);
    expect(r.latitude, isNull);
  });

  Future<void> pumpChip(
    WidgetTester tester,
    void Function(String text, {String? displayLabel}) onSend,
  ) async {
    await tester.pumpWidget(localizedTestApp(
      home: Scaffold(body: NearMeChip(onSend: onSend)),
    ));
  }

  testWidgets('no fix opens the manual dialog; typed place sends unlabeled',
      (WidgetTester tester) async {
    final sent = <(String, String?)>[];
    await pumpChip(
        tester, (text, {displayLabel}) => sent.add((text, displayLabel)));

    await tester.tap(find.text("What's near me?"));
    await tester.pumpAndSettle();

    expect(find.text('Where are you?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  Athens  ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(sent.single.$1, contains('Athens'));
    // Trimmed, and phrased as the traveler's own words — no coordinates.
    expect(sent.single.$1, isNot(contains('  Athens')));
    expect(sent.single.$1, isNot(contains('latitude')));
    // No displayLabel: the manual message renders as a normal bubble.
    expect(sent.single.$2, isNull);
    expect(find.text('Where are you?'), findsNothing);
  });

  testWidgets('empty input cannot submit; cancel sends nothing',
      (WidgetTester tester) async {
    var sends = 0;
    await pumpChip(tester, (text, {displayLabel}) => sends++);

    await tester.tap(find.text("What's near me?"));
    await tester.pumpAndSettle();

    // Ask stays disabled while the field is empty/whitespace.
    final askButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Ask'));
    expect(askButton.onPressed, isNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Ask'))
            .onPressed,
        isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(find.text('Where are you?'), findsNothing);
  });

  testWidgets('chip copy is localized (Spanish)', (WidgetTester tester) async {
    await tester.pumpWidget(localizedTestApp(
      locale: const Locale('es'),
      home: Scaffold(body: NearMeChip(onSend: (t, {displayLabel}) {})),
    ));
    expect(find.text('¿Qué hay cerca de mí?'), findsOneWidget);

    await tester.tap(find.text('¿Qué hay cerca de mí?'));
    await tester.pumpAndSettle();
    expect(find.text('¿Dónde estás?'), findsOneWidget);
  });
}
