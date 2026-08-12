import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/admin_insights.dart';
import 'package:travel_route_planner/models/admin_metrics.dart';
import 'package:travel_route_planner/providers/admin_metrics_provider.dart';
import 'package:travel_route_planner/screens/admin_metrics_screen.dart';

// The Overview tab (default) watches totals alongside the windowed metrics;
// tests that only exercise Overview still need this override so the totals
// section resolves instead of hitting the (blocked) test network.
const _totals = AdminTotals(
  users: 9,
  verifiedUsers: 4,
  onboardedUsers: 6,
  trips: 17,
  tripLineages: 11,
  itineraryItems: 88,
  bookingTodos: 21,
  publishedLocalRecs: 14,
  localGuides: 3,
  activeCollaborators: 1,
  activeShares: 5,
  // Distinct from every value the Overview assertions look for by exact text.
  activeSessions: 19,
  analyticsEvents: 1234,
);

void main() {
  testWidgets('renders funnel and AI tiles from metrics',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const metrics = AdminMetrics(
      days: 30,
      landingViews: 350,
      signups: 42,
      activatedSignups: 21,
      activationRate: 0.5,
      tripsCreated: 30,
      attachRate: 0.15,
      bookingClicks: 12,
      bookingClicksAnonymous: 3,
      clicksByProvider: {'booking': 8, 'airbnb': 4},
      clicksByProviderAnonymous: {'booking': 3},
      secondTripRetention: 7,
      activeUsers: 60,
      planSessions: 100,
      planSessionsAnonymous: 40,
      agentLoopCapHits: 2,
      planInputTokens: 1500000,
      planOutputTokens: 250000,
      planCacheReadTokens: 900000,
      estClaudeCostUsd: 12.5,
      estCogsPerActiveUser: 0.21,
      freeCapWouldHits: {'plan_runs': 3, 'active_trips': 1},
      freeCapUsersAffected: {'plan_runs': 2, 'active_trips': 1},
      placesCallsSinceProcessStart: PlacesCalls(
        search: UpstreamCallCounts(upstream: 100, cacheHits: 400),
        autocomplete: UpstreamCallCounts(upstream: 50, cacheHits: 10),
        details: UpstreamCallCounts(upstream: 25, cacheHits: 5),
        estPlacesCostUsd: 3.77,
      ),
      eventsCallsSinceProcessStart:
          UpstreamCallCounts(upstream: 9, cacheHits: 3),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30).overrideWith((ref) async => metrics),
          adminTotalsProvider.overrideWith((ref) async => _totals),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // All-time totals ride above the windowed funnel on the Overview tab.
    expect(find.text('All-time totals'), findsOneWidget);
    expect(find.text('1234'), findsOneWidget); // analytics events
    expect(find.text('4 verified · 6 onboarded'), findsOneWidget);
    expect(find.text('11 lineages'), findsOneWidget);

    expect(find.text('42'), findsOneWidget); // signups
    expect(find.text('Landing views'), findsOneWidget);
    expect(find.text('350'), findsOneWidget);
    expect(find.text('directional — anonymous, rate-limit bounded'),
        findsOneWidget);
    // Booking-clicks tile carries the anonymous share as its caption.
    expect(find.text('12'), findsOneWidget);
    expect(find.text('3 anonymous'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget); // activation rate
    expect(find.text('15.0%'), findsOneWidget); // attach rate
    expect(find.text('40 anonymous'), findsOneWidget);
    expect(find.text('1.5M'), findsOneWidget); // tokens in
    expect(find.text('900.0k from cache'), findsOneWidget);
    expect(find.text('7'), findsOneWidget); // second-trip retention
    expect(find.text('≥2 trips ≥7 days apart'), findsOneWidget);
    expect(find.text('60'), findsOneWidget); // MAU
    expect(find.text('\$0.21'), findsOneWidget); // est. cost / active user
    expect(find.text('Claude only, estimate'), findsOneWidget);
    expect(find.text('Agent loop cap hits'), findsOneWidget);
    expect(find.text('Would hit plan cap'), findsOneWidget);
    expect(find.text('2 users affected'), findsOneWidget); // plan_runs cohort
    expect(find.text('Would hit trip cap'), findsOneWidget);
    expect(
        find.text('1 users affected'), findsOneWidget); // active_trips cohort
    expect(find.text('Clicks by provider'), findsOneWidget);
    // The anonymous provider split renders as its own bar list under the
    // authenticated one, so 'booking' labels a row in each.
    expect(find.text('Anonymous clicks by provider'), findsOneWidget);
    expect(find.text('booking'), findsNWidgets(2));

    // Provider-call counters: honestly labeled as since-restart, with the
    // per-class breakdown and the Places cost estimate.
    expect(find.text('Provider APIs (since restart)'), findsOneWidget);
    expect(find.text('Places API (since restart)'), findsOneWidget);
    expect(find.text('175'), findsOneWidget); // total upstream
    expect(find.text('415 cache hits · est. \$3.77'), findsOneWidget);
    expect(find.text('100 search'), findsOneWidget);
    expect(find.text('50 autocomplete · 25 details'), findsOneWidget);
    expect(find.text('Events API (since restart)'), findsOneWidget);
    expect(find.text('3 cache hits · free tier'), findsOneWidget);
  });

  testWidgets('omits provider-call section when the API predates it',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // An older API omits the *_since_process_start fields entirely — the
    // model must parse (nullable) and the screen must skip the section.
    final metrics = AdminMetrics.fromJson(const {'days': 30, 'signups': 1});
    expect(metrics.placesCallsSinceProcessStart, isNull);
    expect(metrics.eventsCallsSinceProcessStart, isNull);
    // Same tolerance for the funnel-completion fields (Wave 10): null when
    // absent, and the landing tile / anonymous caption are hidden below.
    expect(metrics.landingViews, isNull);
    expect(metrics.bookingClicksAnonymous, isNull);
    expect(metrics.clicksByProviderAnonymous, isNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30).overrideWith((ref) async => metrics),
          adminTotalsProvider.overrideWith((ref) async => _totals),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Provider APIs (since restart)'), findsNothing);
    expect(find.text('Landing views'), findsNothing);
    expect(find.textContaining('anonymous, rate-limit bounded'), findsNothing);
    expect(find.text('Anonymous clicks by provider'), findsNothing);
    expect(find.text('AI planning'), findsOneWidget);
  });

  testWidgets('omits the anonymous provider split when the map is empty',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Present-but-empty (no anonymous clicks in the window) renders nothing —
    // same as an API that predates the field.
    const metrics = AdminMetrics(
      days: 30,
      signups: 1,
      clicksByProvider: {'booking': 8},
      clicksByProviderAnonymous: {},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30).overrideWith((ref) async => metrics),
          adminTotalsProvider.overrideWith((ref) async => _totals),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clicks by provider'), findsOneWidget);
    expect(find.text('booking'), findsOneWidget);
    expect(find.text('Anonymous clicks by provider'), findsNothing);
  });

  testWidgets('error state offers retry', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30)
              .overrideWith((ref) async => throw Exception('403')),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load metrics'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('Trends tab renders one chart per funnel series', (tester) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final start = DateTime.utc(2026, 7, 1);
    final ts = AdminTimeseries(
      days: 7,
      startDay: start,
      series: {
        'user_registered': [
          DailyCount(day: start, n: 2),
          DailyCount(day: start.add(const Duration(days: 3)), n: 5),
        ],
        'trip_created': [DailyCount(day: start, n: 1)],
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30)
              .overrideWith((ref) async => const AdminMetrics(days: 30)),
          adminTotalsProvider.overrideWith((ref) async => _totals),
          // The pane inherits Overview's 30-day default window.
          adminTimeseriesProvider(30).overrideWith((ref) async => ts),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();

    // One chart slot per series, present even when the series is empty.
    for (final title in [
      'Landing views',
      'Signups',
      'Trips created',
      'Plan sessions',
      'Booking clicks',
      'Itinerary items added',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    // Signups window total = 2 + 5.
    expect(find.text('7'), findsWidgets);
  });

  testWidgets('Overview and Trends panes expose pull-to-refresh',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30)
              .overrideWith((ref) async => const AdminMetrics(days: 30)),
          adminTotalsProvider.overrideWith((ref) async => _totals),
          adminTimeseriesProvider(30).overrideWith((ref) async =>
              AdminTimeseries(
                  days: 30,
                  startDay: DateTime.utc(2026, 7, 1),
                  series: const {})),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Overview (the default tab) is refreshable like Activity/Users.
    expect(find.byType(RefreshIndicator), findsOneWidget);

    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  testWidgets('Activity tab lists events with anonymous handling and paging',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final feed = AdminActivityFeed(
      events: [
        AdminActivityEvent(
          id: 'e1',
          eventType: 'trip_created',
          userEmail: 'brian@example.com',
          createdAt: now.subtract(const Duration(minutes: 5)),
        ),
        AdminActivityEvent(
          id: 'e2',
          eventType: 'booking_link_clicked',
          metadata: const {'provider': 'duffel'},
          createdAt: now.subtract(const Duration(hours: 2)),
        ),
      ],
      nextBefore: now.toIso8601String(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30)
              .overrideWith((ref) async => const AdminMetrics(days: 30)),
          adminTotalsProvider.overrideWith((ref) async => _totals),
          adminActivityProvider.overrideWith((ref) async => feed),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();

    expect(find.text('Trip created'), findsOneWidget);
    expect(find.text('brian@example.com'), findsOneWidget);
    expect(find.text('5m ago'), findsOneWidget);
    expect(find.text('Booking link clicked'), findsOneWidget);
    expect(find.text('anonymous · duffel'), findsOneWidget);
    expect(find.text('2h ago'), findsOneWidget);
    // A full cursor means more pages.
    expect(find.text('Load more'), findsOneWidget);
  });

  testWidgets('Users tab shows aggregates, admin badge, and expands',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final list = AdminUserList(
      total: 2,
      users: [
        AdminUserRow(
          id: 'u1',
          email: 'active@example.com',
          signedUpAt: DateTime(2026, 6, 1),
          onboarded: true,
          emailVerified: true,
          trips: 3,
          tripLineages: 2,
          planSessions: 4,
          bookingClicks: 1,
          planInputTokens: 1500000,
          planOutputTokens: 250000,
          estClaudeCostUsd: 8.25,
          lastEventAt: DateTime.now().subtract(const Duration(days: 2)),
        ),
        AdminUserRow(
          id: 'u2',
          email: 'owner@example.com',
          isAdmin: true,
          signedUpAt: DateTime(2026, 5, 1),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminMetricsProvider(30)
              .overrideWith((ref) async => const AdminMetrics(days: 30)),
          adminTotalsProvider.overrideWith((ref) async => _totals),
          adminUsersProvider(0).overrideWith((ref) async => list),
        ],
        child: const MaterialApp(home: AdminMetricsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 'Users' is also a totals tile label — target the tab specifically.
    await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('Users')));
    await tester.pumpAndSettle();

    expect(find.text('2 users'), findsOneWidget);
    expect(find.text('active@example.com'), findsOneWidget);
    expect(find.text('3 trips · active 2d ago'), findsOneWidget);
    expect(find.text('owner@example.com'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget); // StatusPill on the admin row
    expect(find.text('0 trips · no activity'), findsOneWidget);
    // Both pages fit in total=2, so no load-more.
    expect(find.text('Load more'), findsNothing);

    // Expanding surfaces the aggregates.
    await tester.tap(find.text('active@example.com'));
    await tester.pumpAndSettle();
    expect(find.text('Trip lineages'), findsOneWidget);
    expect(find.text('1.5M / 250.0k'), findsOneWidget);
    expect(find.text('\$8.25'), findsOneWidget);
    expect(find.text('2026-06-01'), findsOneWidget);
  });
}
