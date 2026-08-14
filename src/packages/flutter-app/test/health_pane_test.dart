import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/ops_health.dart';
import 'package:travel_route_planner/models/ops_metrics.dart';
import 'package:travel_route_planner/models/ops_uptime.dart';
import 'package:travel_route_planner/providers/ops_admin_provider.dart';
import 'package:travel_route_planner/widgets/health_pane.dart';

import 'support/l10n_test_app.dart';

const _metrics = OpsMetrics(
  process: ProcessStats(
    uptimeS: 273600, // 3d 4h
    goroutines: 42,
    memAllocBytes: 12 * 1024 * 1024, // 12.0 MB
    memSysBytes: 30 * 1024 * 1024,
    gomaxprocs: 4,
  ),
  requests: RequestMetrics(
    total: 1000,
    byClass: {'2xx': 900, '3xx': 10, '4xx': 80, '5xx': 10},
    routes: [
      RouteMetric(
        route: '/api/v1/trips/{id}',
        method: 'GET',
        count: 120,
        byClass: {'2xx': 110, '4xx': 10},
        errorRate: 0.083,
        p50Ms: 12,
        p95Ms: 85,
        p99Ms: 210,
        meanMs: 22.5,
      ),
    ],
  ),
  upstream: UpstreamStats(placesUpstreamCalls: 12, placesCacheHits: 40),
);

const _health = OpsHealth(
  db: HealthDb(status: 'ok', pingMs: 3),
  providers: [
    ProviderStat(name: 'google_places', configured: true),
    ProviderStat(name: 'email', configured: false, note: 'not configured'),
  ],
  build: BuildInfo(release: 'abc123', goVersion: 'go1.23'),
  backups: BackupInfo(lastSuccessAt: '2026-07-19T04:10:00Z', ageS: 53400),
  degraded: false,
);

Widget _wrap(List<Override> overrides) => ProviderScope(
      overrides: [
        // Every test gets a resolved (empty) uptime history unless it
        // overrides it itself — without this the strip section would hit the
        // blocked test network and render an error into unrelated tests.
        opsUptimeProvider.overrideWith((ref) async => const OpsUptime()),
        ...overrides,
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: Scaffold(body: HealthPane())),
    );

/// Pump the pane through its initial async loads without pumpAndSettle (the
/// pane holds a periodic refresh timer, so pumpAndSettle would never settle),
/// then unmount to cancel that timer before the test ends.
Future<void> _pumpHealth(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(w);
  await tester.pump(); // resolve overridden futures
  await tester.pump();
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox()); // dispose → cancels the timer
  await tester.pump();
}

void main() {
  testWidgets('renders KPI tiles, dependency pills, backup, and a route row',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpHealth(
      tester,
      _wrap([
        opsMetricsProvider.overrideWith((ref) async => _metrics),
        opsHealthProvider.overrideWith((ref) async => _health),
      ]),
    );

    // KPI tiles. ("Process uptime", not "Uptime" — that word now belongs to
    // the 90-day availability section.)
    expect(find.text('Process uptime'), findsOneWidget);
    expect(find.text('3d 4h'), findsOneWidget);
    expect(find.text('Requests'), findsOneWidget);
    expect(find.text('Error rate'), findsOneWidget);
    expect(find.text('9.0%'), findsOneWidget); // (80 + 10) / 1000
    expect(find.text('Goroutines'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('12.0 MB'), findsOneWidget); // mem alloc

    // Dependencies: DB ok pill + provider configured / not-configured pills.
    expect(find.text('Database'), findsOneWidget);
    expect(find.text('3 ms ping'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('Google places'), findsOneWidget);
    expect(find.text('configured'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('not configured'), findsWidgets); // pill + note

    // Backups.
    expect(find.text('Last backup'), findsOneWidget);
    expect(find.text('fresh'), findsOneWidget);
    expect(find.textContaining('ago'), findsOneWidget);

    // Route table row.
    expect(find.text('/api/v1/trips/{id}'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    expect(find.text('85'), findsOneWidget); // p95

    // No degraded banner when healthy.
    expect(find.text('System degraded'), findsNothing);

    await _teardown(tester);
  });

  testWidgets('degraded + stale backup + unreachable DB render red',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const health = OpsHealth(
      db: HealthDb(status: 'unreachable'),
      providers: [],
      backups: BackupInfo(stale: true, ageS: 900000),
      degraded: true,
      reasons: ['database unreachable', 'backup is stale'],
    );

    await _pumpHealth(
      tester,
      _wrap([
        opsMetricsProvider.overrideWith((ref) async => _metrics),
        opsHealthProvider.overrideWith((ref) async => health),
      ]),
    );

    expect(find.text('System degraded'), findsOneWidget);
    expect(find.textContaining('database unreachable'), findsOneWidget);
    expect(find.text('unreachable'), findsOneWidget);
    expect(find.text('stale'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('loading state shows a spinner', (tester) async {
    final never = Completer<OpsMetrics>();
    final neverH = Completer<OpsHealth>();
    await tester.pumpWidget(_wrap([
      opsMetricsProvider.overrideWith((ref) => never.future),
      opsHealthProvider.overrideWith((ref) => neverH.future),
    ]));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsWidgets);

    await _teardown(tester);
  });

  testWidgets('error state offers retry', (tester) async {
    await _pumpHealth(
      tester,
      _wrap([
        opsMetricsProvider
            .overrideWith((ref) async => throw Exception('403')),
        opsHealthProvider.overrideWith((ref) async => _health),
      ]),
    );

    expect(find.text('Could not load metrics'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await _teardown(tester);
  });
}
