import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/widgets/continue_trip_hero.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';
import 'support/url_sync_fakes.dart';

/// The continue hero's own contract: the text block (title, dates, countdown
/// pill) renders on the brand-gradient fallback when the route imagery has
/// nothing to show, and the countdown states only what [daysUntilTrip] can
/// stand behind — future dates count down, past/unknown dates show no pill
/// at all. Imagery-on-cache-hit lives in home_recent_trip_map_test, which
/// pumps the real cache seam.
String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<void> _pump(
  WidgetTester tester, {
  required String? startDate,
  String? dateRange = 'Sep 1 – Sep 8',
  VoidCallback? onTap,
  double textScale = 1.0,
}) async {
  // Empty prefs: the cache read behind TripMapBand misses, so the hero
  // exercises its gradient-fallback layer.
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: ContinueTripHero(
            tripId: 't1',
            title: 'Big Summer Adventure',
            dateRange: dateRange,
            startDate: startDate,
            onTap: onTap ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Tomorrow/today by CALENDAR arithmetic, never `add(Duration(days: 1))`:
/// an absolute-time offset lands on the wrong calendar date across a DST
/// transition, and `daysUntilTrip` counts calendar days.
DateTime _todayPlus(int days) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + days);
}

void main() {
  testWidgets('fallback hero still carries title and dates without imagery',
      (WidgetTester tester) async {
    await _pump(tester, startDate: null);

    expect(find.byType(TripMap), findsNothing);
    expect(find.text('Big Summer Adventure'), findsOneWidget);
    expect(find.text('Sep 1 – Sep 8'), findsOneWidget);
  });

  testWidgets('future start date renders the countdown pill',
      (WidgetTester tester) async {
    await _pump(tester, startDate: _iso(_todayPlus(1)));

    expect(find.byType(StatusPill), findsOneWidget);
    expect(find.text('Starts tomorrow'), findsOneWidget);
  });

  testWidgets('a trip starting today says so — the countdown boundary',
      (WidgetTester tester) async {
    await _pump(tester, startDate: _iso(_todayPlus(0)));

    expect(find.byType(StatusPill), findsOneWidget);
    expect(find.text('Starts today'), findsOneWidget);
  });

  testWidgets('a start date behind today shows no pill rather than a wrong one',
      (WidgetTester tester) async {
    await _pump(tester, startDate: _iso(_todayPlus(-7)));

    expect(find.byType(StatusPill), findsNothing);
  });

  testWidgets('accessibility text scale grows the card instead of clipping',
      (WidgetTester tester) async {
    // 360-wide phone at 2.0x — the worst documented case: two title lines
    // plus a wrapped meta row. The hero must grow (its height scales by the
    // text band) and overflow nothing.
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, startDate: _iso(_todayPlus(1)), textScale: 2.0);

    expect(tester.takeException(), isNull);
    expect(find.text('Big Summer Adventure'), findsOneWidget);
    expect(find.text('Starts tomorrow'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ContinueTripHero)).height,
      greaterThan(ContinueTripHero.baseHeight),
    );
  });

  testWidgets('no start date (the snapshot rung) means no pill',
      (WidgetTester tester) async {
    await _pump(tester, startDate: null);

    expect(find.byType(StatusPill), findsNothing);
  });

  testWidgets('an undated trip drops the meta line but keeps the title',
      (WidgetTester tester) async {
    await _pump(tester, startDate: null, dateRange: null);

    expect(find.text('Big Summer Adventure'), findsOneWidget);
    expect(find.byType(StatusPill), findsNothing);
  });

  testWidgets('the whole card is one tap target', (WidgetTester tester) async {
    var taps = 0;
    await _pump(tester, startDate: null, onTap: () => taps++);

    await tester.tap(find.byType(ContinueTripHero));
    expect(taps, 1);
  });
}
