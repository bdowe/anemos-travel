import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/app_shell.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/url_sync_fakes.dart';

/// The write half of URL persistence (specs/url-page-persistence): every
/// page change — tab switch, located push, pop, sign-out — must land in the
/// address bar, and unnamed routes must leave it alone.
void main() {
  late FakeAuthNotifier auth;
  late List<String> reports;

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    auth = FakeAuthNotifier(fakeUser());
    reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => auth),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t1'))),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue(reports.add),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
        tester.element(find.byType(TravelRoutePlannerApp)));
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tab switches report each tab root', (tester) async {
    final container = await pumpApp(tester);
    expect(reports.last, '/');

    container.read(navIndexProvider.notifier).state = AppTab.plan.index;
    await tester.pumpAndSettle();
    expect(reports.last, '/plan');

    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');
  });

  testWidgets('opening and closing a trip keeps the URL in step',
      (tester) async {
    final container = await pumpApp(tester);
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');
  });

  testWidgets('per-tab memory: switching away and back restores the page URL',
      (tester) async {
    final container = await pumpApp(tester);
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(reports.last, '/trips/t1');

    container.read(navIndexProvider.notifier).state = AppTab.home.index;
    await tester.pumpAndSettle();
    expect(reports.last, '/');

    // IndexedStack kept the trips stack alive, so the URL must say so too.
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();
    expect(reports.last, '/trips/t1');
  });

  testWidgets('unnamed pushes leave the URL at the page beneath',
      (tester) async {
    final container = await pumpApp(tester);
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');

    // An in-tab unnamed push (the LocalGuideDetail/FlightSearch class of
    // screens): no report.
    final tabNav = container
        .read(tabNavKeysProvider)[AppTab.trips.index]
        .currentState!;
    tabNav.push(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('unnamed page'))));
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');

    tabNav.pop();
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');

    // A root-navigator unnamed push + pop (the TripMapScreen shape): the
    // root observer re-asserts, so the last word stays the shell's location.
    final rootNav = Navigator.of(tester.element(find.byType(AppShell)),
        rootNavigator: true);
    rootNav.push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const Scaffold(body: Text('fullscreen dialog'))));
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');

    rootNav.pop();
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');
  });

  testWidgets('signing out resets the URL to the root', (tester) async {
    final container = await pumpApp(tester);
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');

    auth.signOut();
    await tester.pumpAndSettle();
    expect(reports.last, '/');
  });
}
