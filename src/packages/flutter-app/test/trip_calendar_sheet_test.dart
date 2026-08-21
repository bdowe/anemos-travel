import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/widgets/trip_calendar_sheet.dart';

import 'support/l10n_test_app.dart';

// Pure widget tests for the trip calendar sheet body: the whole-trip month
// grid with one check-in → check-out ribbon per city leg. No providers, no
// network — the body renders the legs it is handed (the screen builds them
// from the trip-detail derivation's visibleRanges).

/// Mon Aug 24 – Tue Sep 22, 2026 (30 days), three legs sharing their
/// boundary days exactly the way the derivation's visible ranges do:
/// Athens 5 nights, Kraków 5, Prague 19 — 29 nights over 30 days.
final _legs = <TripCalendarLeg>[
  (key: 'Athens', label: 'Athens', start: DateTime(2026, 8, 24), end: DateTime(2026, 8, 29)),
  (key: 'Kraków', label: 'Kraków', start: DateTime(2026, 8, 29), end: DateTime(2026, 9, 3)),
  (key: 'Prague', label: 'Prague', start: DateTime(2026, 9, 3), end: DateTime(2026, 9, 22)),
];

Widget _app({
  List<TripCalendarLeg>? legs,
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
            legs: legs ?? _legs,
            today: today,
            onJumpToDay: onJumpToDay ?? (_) {},
            onAskToChange: onAskToChange,
          ),
        ),
      ),
    );

Future<void> _pump(
  WidgetTester tester, {
  List<TripCalendarLeg>? legs,
  ValueChanged<int>? onJumpToDay,
  ValueChanged<TripCalendarLeg>? onAskToChange,
  DateTime? today,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(
    legs: legs,
    onJumpToDay: onJumpToDay,
    onAskToChange: onAskToChange,
    today: today,
  ));
  await tester.pumpAndSettle();
}

/// The whole-cell band a day inside a stay carries.
Container _solid(WidgetTester tester, String isoDate) =>
    tester.widget<Container>(
        find.byKey(ValueKey('trip-calendar-band-$isoDate')));

/// The left half of a day: the leg CHECKING OUT.
Container _checkOut(WidgetTester tester, String isoDate) =>
    tester.widget<Container>(
        find.byKey(ValueKey('trip-calendar-checkout-$isoDate')));

/// The right half of a day: the leg CHECKING IN.
Container _checkIn(WidgetTester tester, String isoDate) =>
    tester.widget<Container>(
        find.byKey(ValueKey('trip-calendar-checkin-$isoDate')));

Color? _fill(Container c) =>
    c.color ?? (c.decoration as BoxDecoration?)?.color;

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

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

  testWidgets('a shared boundary day carries BOTH cities — out left, in right',
      (tester) async {
    await _pump(tester);

    // Aug 29 is Athens' check-out and Kraków's check-in. The day is split,
    // not awarded to one of them: the left half is the city being left.
    expect(_fill(_checkOut(tester, '2026-08-29')), AppColors.legBand(0));
    expect(_fill(_checkIn(tester, '2026-08-29')), AppColors.legBand(1));
    // Sep 3 does the same for Kraków → Prague.
    expect(_fill(_checkOut(tester, '2026-09-03')), AppColors.legBand(1));
    expect(_fill(_checkIn(tester, '2026-09-03')), AppColors.legBand(2));

    // Nights strictly inside a stay are solid.
    expect(_fill(_solid(tester, '2026-08-26')), AppColors.legBand(0));
    expect(_fill(_solid(tester, '2026-08-30')), AppColors.legBand(1));

    // The trip's first day is a check-in with nothing to check out of; its
    // last day is the mirror — the journey home.
    expect(_fill(_checkIn(tester, '2026-08-24')), AppColors.legBand(0));
    expect(find.byKey(const ValueKey('trip-calendar-checkout-2026-08-24')),
        findsNothing);
    expect(_fill(_checkOut(tester, '2026-09-22')), AppColors.legBand(2));
    expect(find.byKey(const ValueKey('trip-calendar-checkin-2026-09-22')),
        findsNothing);

    // Days outside the trip carry no ribbon.
    expect(find.byKey(const ValueKey('trip-calendar-band-2026-08-23')),
        findsNothing);
  });

  testWidgets('a ribbon is exactly as long as the leg has nights',
      (tester) async {
    await _pump(tester);

    // The regression this whole shape exists for: the band and the nights
    // label used to disagree on screen. Half-cells at each end mean a stay's
    // ink measures its night count in cell-widths, for every leg — not
    // nights+1 for the first and nights-shifted-a-day for the rest.
    for (var i = 0; i < _legs.length; i++) {
      var width = 0.0;
      for (var d = DateTime(2026, 8, 24);
          !d.isAfter(DateTime(2026, 9, 22));
          d = DateTime(d.year, d.month, d.day + 1)) {
        final iso = _iso(d);
        final tone = AppColors.legBand(i);
        if (find.byKey(ValueKey('trip-calendar-band-$iso')).evaluate().isEmpty) {
          continue;
        }
        if (find
                .byKey(ValueKey('trip-calendar-checkout-$iso'))
                .evaluate()
                .isNotEmpty &&
            _fill(_checkOut(tester, iso)) == tone) {
          width += 0.5;
        }
        if (find
                .byKey(ValueKey('trip-calendar-checkin-$iso'))
                .evaluate()
                .isNotEmpty &&
            _fill(_checkIn(tester, iso)) == tone) {
          width += 0.5;
        }
        if (find.byKey(ValueKey('trip-calendar-checkout-$iso')).evaluate().isEmpty &&
            find.byKey(ValueKey('trip-calendar-checkin-$iso')).evaluate().isEmpty &&
            _fill(_solid(tester, iso)) == tone) {
          width += 1;
        }
      }
      expect(width, _legs[i].end.difference(_legs[i].start).inDays.toDouble(),
          reason: '${_legs[i].label} ribbon must measure its nights');
    }
  });

  testWidgets('caps round only where a stay begins or ends', (tester) async {
    await _pump(tester);

    BorderRadius radiusOf(Container c) =>
        (c.decoration! as BoxDecoration).borderRadius! as BorderRadius;

    // The check-out half rounds where it stops, mid-cell, and stays square
    // against the night before it...
    final out = radiusOf(_checkOut(tester, '2026-08-29'));
    expect(out.topRight, const Radius.circular(8));
    expect(out.topLeft, Radius.zero);
    // ...and the check-in half is its mirror.
    final into = radiusOf(_checkIn(tester, '2026-08-29'));
    expect(into.topLeft, const Radius.circular(8));
    expect(into.topRight, Radius.zero);

    // A night inside a stay has no radius at all, so cells merge across a
    // row and across a month wrap.
    expect((_solid(tester, '2026-08-26').decoration as BoxDecoration?)?.borderRadius,
        isNull);
  });

  testWidgets('the key names the two-tone day, and only when one can occur',
      (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('trip-calendar-key')), findsOneWidget);
    expect(
      find.text('A day in two colors is a travel day — you check out of one '
          'city and into the next.'),
      findsOneWidget,
    );

    // A one-city trip never draws a split cell, so it never explains one.
    await _pump(tester, legs: [_legs.first]);
    expect(find.byKey(const ValueKey('trip-calendar-key')), findsNothing);
  });

  testWidgets('a zero-night stop stays visible as a pip', (tester) async {
    // The interim state a set_leg_dates squeeze leaves behind: Kraków ends
    // the day it starts. It owned no whole cell under the old rule and
    // vanished from the grid entirely.
    await _pump(tester, legs: [
      (key: 'Athens', label: 'Athens', start: DateTime(2026, 8, 24), end: DateTime(2026, 8, 29)),
      (key: 'Kraków', label: 'Kraków', start: DateTime(2026, 8, 29), end: DateTime(2026, 8, 29)),
      (key: 'Prague', label: 'Prague', start: DateTime(2026, 8, 29), end: DateTime(2026, 9, 22)),
    ]);

    final pip = find.byKey(const ValueKey('trip-calendar-stop-2026-08-29'));
    expect(pip, findsOneWidget);
    expect(
      (tester.widget<Container>(pip).decoration! as BoxDecoration).color,
      AppColors.legTone(1),
    );
    // Athens still checks out that day and Prague still checks in.
    expect(_fill(_checkOut(tester, '2026-08-29')), AppColors.legBand(0));
    expect(_fill(_checkIn(tester, '2026-08-29')), AppColors.legBand(2));
  });

  testWidgets('selecting a leg mutes the others so its run reads as one',
      (tester) async {
    await _pump(tester);
    expect(_fill(_solid(tester, '2026-08-30')), AppColors.legBand(1));

    await tester.tap(find.byKey(const ValueKey('trip-calendar-legend-1')));
    await tester.pumpAndSettle();

    // Kraków keeps its full wash; Athens drops back.
    expect(_fill(_solid(tester, '2026-08-30')), AppColors.legBand(1));
    expect(_fill(_solid(tester, '2026-08-26')),
        AppColors.legBand(0, muted: true));
    // Its two boundary halves are exactly where the ribbon starts and stops.
    expect(_fill(_checkIn(tester, '2026-08-29')), AppColors.legBand(1));
    expect(_fill(_checkOut(tester, '2026-08-29')),
        AppColors.legBand(0, muted: true));
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
    // The row names both ends rather than printing the span, so the night
    // count beside it can't be read against a range the traveler is still
    // deciding how to count.
    expect(
      find.descendant(
          of: detail,
          matching: find.text(
              'Check in Sat, Aug 29 · Check out Thu, Sep 3 · 5 nights')),
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
