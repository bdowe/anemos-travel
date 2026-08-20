import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/widgets/trip_calendar_sheet.dart';

import 'support/l10n_test_app.dart';

// Pure widget tests for the trip calendar sheet body: the whole-trip month
// grid with one color band per city leg. No providers, no network — the body
// renders the legs it is handed (the screen builds them from the trip-detail
// derivation's visibleRanges).

/// Mon Aug 24 – Tue Sep 22, 2026 (30 days), three legs sharing their
/// boundary days exactly the way the derivation's visible ranges do.
final _legs = <TripCalendarLeg>[
  (key: 'Athens', label: 'Athens', start: DateTime(2026, 8, 24), end: DateTime(2026, 8, 29)),
  (key: 'Kraków', label: 'Kraków', start: DateTime(2026, 8, 29), end: DateTime(2026, 9, 3)),
  (key: 'Prague', label: 'Prague', start: DateTime(2026, 9, 3), end: DateTime(2026, 9, 22)),
];

Widget _app({
  ValueChanged<int>? onJumpToDay,
  ValueChanged<TripCalendarLeg>? onAskToChange,
  DateTime? today,
}) =>
    localizedTestApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TripCalendarSheetBody(
            tripStart: DateTime(2026, 8, 24),
            tripEnd: DateTime(2026, 9, 22),
            legs: _legs,
            today: today,
            onJumpToDay: onJumpToDay ?? (_) {},
            onAskToChange: onAskToChange,
          ),
        ),
      ),
    );

Future<void> _pump(
  WidgetTester tester, {
  ValueChanged<int>? onJumpToDay,
  ValueChanged<TripCalendarLeg>? onAskToChange,
  DateTime? today,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(
    onJumpToDay: onJumpToDay,
    onAskToChange: onAskToChange,
    today: today,
  ));
  await tester.pumpAndSettle();
}

Container _band(WidgetTester tester, String isoDate) => tester.widget<Container>(
    find.byKey(ValueKey('trip-calendar-band-$isoDate')));

void main() {
  testWidgets('header, summary, month and weekday headers', (tester) async {
    await _pump(tester);

    expect(find.text('Trip calendar'), findsOneWidget);
    expect(find.text('Aug 24 – Sep 22 · 30 days · 3 cities'), findsOneWidget);
    expect(find.text('August 2026'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('MON'), findsWidgets);
    expect(find.text('SAT'), findsWidgets);
    expect(find.text('SUN'), findsWidgets);
  });

  testWidgets('one legend chip per leg', (tester) async {
    await _pump(tester);

    for (var i = 0; i < _legs.length; i++) {
      expect(find.byKey(ValueKey('trip-calendar-legend-$i')), findsOneWidget);
    }
    expect(find.text('Athens'), findsOneWidget);
    expect(find.text('Kraków'), findsOneWidget);
    expect(find.text('Prague'), findsOneWidget);
  });

  testWidgets('leg bands: shared boundary day belongs to the city being left',
      (tester) async {
    await _pump(tester);

    // Aug 29 is both Athens' end and Kraków's start; the band stays Athens'.
    expect(_band(tester, '2026-08-29').decoration,
        isA<BoxDecoration>().having((d) => d.color, 'color', AppColors.legBand(0)));
    // Kraków's band starts the next day.
    expect(_band(tester, '2026-08-30').decoration,
        isA<BoxDecoration>().having((d) => d.color, 'color', AppColors.legBand(1)));
    // ...and runs through the shared Sep 3; Prague starts Sep 4.
    expect(_band(tester, '2026-09-03').decoration,
        isA<BoxDecoration>().having((d) => d.color, 'color', AppColors.legBand(1)));
    expect(_band(tester, '2026-09-04').decoration,
        isA<BoxDecoration>().having((d) => d.color, 'color', AppColors.legBand(2)));
    // Days outside the trip carry no band.
    expect(find.byKey(const ValueKey('trip-calendar-band-2026-08-23')),
        findsNothing);
  });

  testWidgets('band caps round at the leg\'s owned start and end only',
      (tester) async {
    await _pump(tester);

    BorderRadius radiusOf(String iso) =>
        (_band(tester, iso).decoration! as BoxDecoration).borderRadius!
            as BorderRadius;

    // Athens owns Aug 24–29: rounded caps at both ends...
    expect(radiusOf('2026-08-24').topLeft, const Radius.circular(8));
    expect(radiusOf('2026-08-29').topRight, const Radius.circular(8));
    // ...square in the middle so adjacent cells read as one band...
    expect(radiusOf('2026-08-26').topLeft, Radius.zero);
    expect(radiusOf('2026-08-26').topRight, Radius.zero);
    // ...and Kraków's cap lands on its first OWNED day (Aug 30), not the
    // shared boundary.
    expect(radiusOf('2026-08-30').topLeft, const Radius.circular(8));
  });

  testWidgets('weekend columns get the wash, weekdays do not', (tester) async {
    await _pump(tester);

    // Aug 29/30, 2026 are Saturday/Sunday; Aug 28 is a Friday.
    expect(find.byKey(const ValueKey('trip-calendar-weekend-2026-08-29')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('trip-calendar-weekend-2026-08-30')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('trip-calendar-weekend-2026-08-28')),
        findsNothing);
  });

  testWidgets('today gets the filled-circle marker only inside the trip',
      (tester) async {
    await _pump(tester, today: DateTime(2026, 8, 26));
    expect(find.byKey(const ValueKey('trip-calendar-today')), findsOneWidget);

    await _pump(tester, today: DateTime(2026, 10, 5));
    expect(find.byKey(const ValueKey('trip-calendar-today')), findsNothing);
  });

  testWidgets('legend chip shows the detail row with range, nights, weekends',
      (tester) async {
    await _pump(tester, onAskToChange: (_) {});

    expect(find.byKey(const ValueKey('trip-calendar-detail')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('trip-calendar-legend-1')));
    await tester.pumpAndSettle();

    final detail = find.byKey(const ValueKey('trip-calendar-detail'));
    expect(detail, findsOneWidget);
    expect(
        find.descendant(of: detail, matching: find.text('Kraków')),
        findsOneWidget);
    expect(
      find.descendant(
          of: detail, matching: find.text('Sat, Aug 29 – Thu, Sep 3 · 5 nights')),
      findsOneWidget,
    );
    // Aug 29 (Sat) and Aug 30 (Sun) are the leg's two weekend days.
    expect(
      find.descendant(of: detail, matching: find.text('2 WEEKEND DAYS')),
      findsOneWidget,
    );

    // Tapping the same chip again dismisses the detail row.
    await tester.tap(find.byKey(const ValueKey('trip-calendar-legend-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('trip-calendar-detail')), findsNothing);
  });

  testWidgets('tapping a trip day reports its 1-based trip day', (tester) async {
    final jumped = <int>[];
    await _pump(tester, onJumpToDay: jumped.add);

    await tester.tap(find.byKey(const ValueKey('trip-calendar-day-2026-08-31')));
    await tester.pumpAndSettle();
    expect(jumped, [8]); // Aug 24 is day 1, so Aug 31 is day 8.

    // Days outside the trip are not tappable.
    await tester.tap(find.byKey(const ValueKey('trip-calendar-day-2026-08-20')));
    await tester.pumpAndSettle();
    expect(jumped, [8]);
  });

  testWidgets('Ask to change hands the selected leg to its callback',
      (tester) async {
    TripCalendarLeg? asked;
    await _pump(tester, onAskToChange: (leg) => asked = leg);

    await tester.tap(find.byKey(const ValueKey('trip-calendar-legend-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask to change'));
    await tester.pumpAndSettle();

    expect(asked?.label, 'Kraków');
    expect(asked?.start, DateTime(2026, 8, 29));
    expect(asked?.end, DateTime(2026, 9, 3));
  });

  testWidgets('a null onAskToChange hides the button (viewers, offline)',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('trip-calendar-legend-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trip-calendar-detail')), findsOneWidget);
    expect(find.text('Ask to change'), findsNothing);
  });
}
