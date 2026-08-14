import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/ops_health.dart';
import 'package:travel_route_planner/models/ops_metrics.dart';
import 'package:travel_route_planner/models/ops_uptime.dart';
import 'package:travel_route_planner/providers/ops_admin_provider.dart';
import 'package:travel_route_planner/theme/app_theme.dart';
import 'package:travel_route_planner/utils/date_formats.dart';
import 'package:travel_route_planner/widgets/health_pane.dart';
import 'package:travel_route_planner/widgets/uptime_strip.dart';

import 'support/l10n_test_app.dart';

// Same test discipline as health_pane_test.dart: never pumpAndSettle (the
// pane holds a 10s periodic timer), oversize the viewport so the ListView
// renders whole, and unmount at the end to cancel the timer.

const _metrics = OpsMetrics(
  process: ProcessStats(uptimeS: 3600, goroutines: 10, gomaxprocs: 2),
  requests: RequestMetrics(total: 10, byClass: {'2xx': 10}),
);

const _health = OpsHealth(
  db: HealthDb(status: 'ok', pingMs: 3),
  providers: [],
  build: BuildInfo(release: 'abc123', goVersion: 'go1.26'),
  backups: BackupInfo(lastSuccessAt: '2026-08-13T04:10:00Z', ageS: 3600),
);

final _day0 = DateTime.utc(2026, 5, 16);

String _dayStr(int i) =>
    _day0.add(Duration(days: i)).toIso8601String().substring(0, 10);

/// 90 green days with [downIdx] as a degraded day (30m down, db unreachable).
List<UptimeDay> _days90({int? downIdx}) => List.generate(90, (i) {
      if (i == downIdx) {
        return UptimeDay(
          day: _dayStr(i),
          state: 'degraded',
          uptimePct: 97.92,
          upS: 84600,
          downS: 1800,
          reasonCodes: const ['db_unreachable'],
        );
      }
      return UptimeDay(
          day: _dayStr(i), state: 'up', uptimePct: 100, upS: 86400);
    });

List<UptimeDay> _noData90() =>
    List.generate(90, (i) => UptimeDay(day: _dayStr(i)));

OpsUptime _uptimeFixture({int? downIdx}) => OpsUptime(
      days: 90,
      startDay: _dayStr(0),
      monitoringSince: DateTime.utc(2026, 5, 16, 8),
      components: [
        UptimeComponent(
            key: 'api',
            status: 'up',
            uptimePct: 99.98,
            observedDays: 90,
            days: _days90(downIdx: downIdx)),
        UptimeComponent(
            key: 'database',
            status: 'up',
            uptimePct: 99.98,
            observedDays: 90,
            days: _days90(downIdx: downIdx)),
        UptimeComponent(
            key: 'ai_provider',
            status: 'down',
            uptimePct: 97.5,
            observedDays: 90,
            days: _days90()),
        UptimeComponent(
            key: 'backups',
            status: 'up',
            uptimePct: 100,
            observedDays: 90,
            days: _days90()),
      ],
    );

OpsUptime _uptimeNoHistory() => OpsUptime(
      days: 90,
      startDay: _dayStr(0),
      monitoringSince: DateTime.utc(2026, 8, 13, 2, 10),
      components: [
        for (final key in ['api', 'database', 'ai_provider', 'backups'])
          UptimeComponent(key: key, status: 'no_data', days: _noData90()),
      ],
    );

Widget _wrap(List<Override> overrides, {ThemeData? theme, Locale? locale}) =>
    ProviderScope(
      overrides: [
        opsMetricsProvider.overrideWith((ref) async => _metrics),
        opsHealthProvider.overrideWith((ref) async => _health),
        ...overrides,
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        supportedLocales: const [Locale('en'), Locale('es')],
        locale: locale,
        theme: theme,
        home: const Scaffold(body: HealthPane()),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(w);
  await tester.pump();
  await tester.pump();
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void _oversize(WidgetTester tester, [Size size = const Size(900, 2800)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The strip band (our CustomPaint) inside the [i]th UptimeStrip.
Finder _band(int i) => find
    .descendant(
        of: find.byType(UptimeStrip).at(i),
        matching: find.byType(CustomPaint))
    .first;

void main() {
  testWidgets('renders four component strips with pills and summary captions',
      (tester) async {
    _oversize(tester);
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider.overrideWith((ref) async => _uptimeFixture()),
        ]));

    expect(find.byType(UptimeStrip), findsNWidgets(4));
    expect(find.text('API'), findsOneWidget);
    expect(find.text('Database'), findsWidgets); // strip + dependencies row
    expect(find.text('AI provider'), findsOneWidget);
    expect(find.text('Backups'), findsWidgets); // strip + backups section
    // Pills: three up + the ai_provider "down".
    expect(find.text('down'), findsOneWidget);
    // Window summaries and the caption trio.
    expect(find.text('99.98 % uptime'), findsNWidgets(2));
    expect(find.text('90 days ago'), findsNWidgets(4));
    expect(find.text('Today'), findsNWidgets(4));
    // The honesty note and the section header.
    expect(find.text('Uptime'), findsOneWidget); // section (tile says Process uptime)
    expect(find.textContaining('Self-check'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('day one: all no_data shows monitoring-since, never a percent',
      (tester) async {
    _oversize(tester);
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider.overrideWith((ref) async => _uptimeNoHistory()),
        ]));

    expect(find.byType(UptimeStrip), findsNWidgets(4));
    // The honest empty caption — and NO invented 0 % / 100 % anywhere.
    expect(find.textContaining('Monitoring since'), findsNWidgets(4));
    expect(find.textContaining('% uptime'), findsNothing);

    await _teardown(tester);
  });

  testWidgets('tapping an outage day shows its date, percent, and reason',
      (tester) async {
    _oversize(tester);
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider
              .overrideWith((ref) async => _uptimeFixture(downIdx: 44)),
        ]));

    final rect = tester.getRect(_band(0));
    await tester.tapAt(Offset(
        rect.left + rect.width * (44 + 0.5) / 90, rect.center.dy));
    await tester.pump();

    final wantDate = mmmd().format(_day0.add(const Duration(days: 44)));
    expect(
        find.textContaining('$wantDate · 97.92 % uptime'), findsOneWidget);
    expect(find.textContaining('database unreachable'), findsOneWidget);
    expect(find.textContaining('30m down'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('arrow keys walk days from Today backwards; Escape clears',
      (tester) async {
    _oversize(tester);
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider.overrideWith((ref) async => _uptimeFixture()),
        ]));

    // Tap the last bar (Today) to focus + select it, then one arrow left
    // steps to yesterday.
    final rect = tester.getRect(_band(0));
    await tester.tapAt(Offset(
        rect.left + rect.width * (89 + 0.5) / 90, rect.center.dy));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    final wantDate = mmmd().format(_day0.add(const Duration(days: 88)));
    expect(find.textContaining(wantDate), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    // Cleared: back to the window summary.
    expect(find.text('99.98 % uptime'), findsNWidgets(2));

    await _teardown(tester);
  });

  testWidgets('uptime error renders retry without blanking the pane',
      (tester) async {
    _oversize(tester);
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider
              .overrideWith((ref) async => throw Exception('503')),
        ]));

    expect(find.text('Could not load uptime'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // The rest of the pane is intact.
    expect(find.text('Process uptime'), findsOneWidget);
    expect(find.text('Goroutines'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('loading shows the fixed-extent skeleton, not a percent',
      (tester) async {
    _oversize(tester);
    final never = Completer<OpsUptime>();
    await tester.pumpWidget(_wrap([
      opsUptimeProvider.overrideWith((ref) => never.future),
    ]));
    await tester.pump();
    await tester.pump();

    expect(find.text('Uptime'), findsOneWidget); // skeleton keeps the header
    expect(find.textContaining('% uptime'), findsNothing);
    // And the sections below still resolved.
    expect(find.text('Process uptime'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('empty components render nothing (server not shipped yet)',
      (tester) async {
    _oversize(tester);
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider.overrideWith((ref) async => const OpsUptime()),
        ]));

    expect(find.byType(UptimeStrip), findsNothing);
    expect(find.text('Uptime'), findsNothing); // whole section absent
    expect(find.text('Process uptime'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('dark theme renders without exceptions', (tester) async {
    _oversize(tester);
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider
              .overrideWith((ref) async => _uptimeFixture(downIdx: 44)),
        ], theme: AppTheme.dark));

    expect(find.byType(UptimeStrip), findsNWidgets(4));
    expect(tester.takeException(), isNull);

    await _teardown(tester);
  });

  testWidgets('360px phone in Spanish renders without overflow',
      (tester) async {
    _oversize(tester, const Size(360, 2800));
    await _pump(
        tester,
        _wrap([
          opsUptimeProvider.overrideWith((ref) async => _uptimeFixture()),
        ], locale: const Locale('es')));

    expect(find.byType(UptimeStrip), findsNWidgets(4));
    // A clean pump with no exception IS the assertion (overflow throws).
    expect(tester.takeException(), isNull);

    await _teardown(tester);
  });

  testWidgets('the 10s timer refreshes metrics but never the uptime history',
      (tester) async {
    _oversize(tester);
    var metricsCalls = 0;
    var uptimeCalls = 0;
    await _pump(
        tester,
        _wrap([
          opsMetricsProvider.overrideWith((ref) async {
            metricsCalls++;
            return _metrics;
          }),
          opsUptimeProvider.overrideWith((ref) async {
            uptimeCalls++;
            return _uptimeFixture();
          }),
        ]));
    expect(metricsCalls, 1);
    expect(uptimeCalls, 1);

    await tester.pump(const Duration(seconds: 11)); // one timer tick
    await tester.pump();

    expect(metricsCalls, 2, reason: 'timer refreshes the live metrics');
    expect(uptimeCalls, 1, reason: 'the 90-day history is not on the timer');

    await _teardown(tester);
  });
}
