import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/constants/app_info.dart';
import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';

import 'support/url_sync_fakes.dart';

/// Nav-button contract (selectTab): Home always lands on its root, while
/// Trips keeps your place — the first tap returns to the trip you were
/// viewing, a second tap pops to the list. The default 800x600 test surface
/// is at kRailBreakpoint, so the NavigationRail renders and taps go through
/// the real nav-button path.
void main() {
  late List<String> reports;

  Finder railDestination(String label) => find.descendant(
      of: find.byType(NavigationRail), matching: find.text(label));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
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

  testWidgets(
      'Trips keeps your place: first tap returns to the trip, second pops to the list',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');

    await tester.tap(railDestination('Home'));
    await tester.pumpAndSettle();
    expect(reports.last, '/');

    // First Trips tap restores the trip that was open (and its URL).
    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');

    // Second tap pops the tab to the list.
    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });

  testWidgets('the Home button always lands on the Home root',
      (tester) async {
    // Home is not a stack-keeping tab: a page left on its stack (utility
    // pushes via pushOnActiveTab land there) must not greet the user on the
    // next Home tap. Pop-before-switch also keeps the stale page's URL out
    // of the address bar.
    final container = await pumpApp(tester);

    container
        .read(tabNavKeysProvider)[AppTab.home.index]
        .currentState!
        .push(locatedRoute(
            const Scaffold(body: Text('stacked on home')), '/preferences'));
    await tester.pumpAndSettle();
    expect(find.text('stacked on home'), findsOneWidget);
    expect(reports.last, '/preferences');

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(reports.last, '/trips');
    final reportsAfterTrips = reports.length;

    await tester.tap(railDestination('Home'));
    await tester.pumpAndSettle();
    expect(find.text('stacked on home'), findsNothing);
    expect(reports.last, '/');
    // Pop-before-switch: the stacked page's didPop drains while Trips is
    // still the active tab, so '/preferences' never reaches the address bar.
    expect(reports.sublist(reportsAfterTrips), isNot(contains('/preferences')));
  });

  testWidgets('the Home button leaves nothing behind to animate away',
      (tester) async {
    // The artifact this pins: selectTab used to POP the destination tab's
    // stack, and the shell freezes hidden tabs' tickers (app_shell.dart), so
    // that pop parked fully painted and then played its whole exit transition
    // the moment the IndexedStack revealed the tab — you tapped Home and
    // watched a page you had left there slide away. The case above cannot see
    // it because pumpAndSettle pumps straight past it, so assert on the very
    // next frame instead. skipOffstage: false because the contract is that
    // the route is GONE, not merely hidden.
    final container = await pumpApp(tester);

    container
        .read(tabNavKeysProvider)[AppTab.home.index]
        .currentState!
        .push(locatedRoute(
            const Scaffold(body: Text('stacked on home')), '/preferences'));
    await tester.pumpAndSettle();

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();

    await tester.tap(railDestination('Home'));
    await tester.pump();
    expect(find.text('stacked on home', skipOffstage: false), findsNothing,
        reason: 'the stale page must already be gone, not mid-transition');
  });

  testWidgets('re-tapping the active tab still animates its pop',
      (tester) async {
    // The other half of selectTab's split: a re-tap happens on a tab you can
    // see and IS the gesture, so it keeps the ordinary animated pop. Same
    // single-frame probe as above, with the opposite expectation.
    final container = await pumpApp(tester);

    container
        .read(tabNavKeysProvider)[AppTab.home.index]
        .currentState!
        .push(locatedRoute(
            const Scaffold(body: Text('stacked on home')), '/preferences'));
    await tester.pumpAndSettle();

    await tester.tap(railDestination('Home'));
    await tester.pump();
    expect(find.text('stacked on home', skipOffstage: false), findsOneWidget,
        reason: 'a re-tap pops with a transition, so the page is still there');

    await tester.pumpAndSettle();
    expect(find.text('stacked on home', skipOffstage: false), findsNothing);
    expect(reports.last, '/');
  });

  testWidgets('the rail brand mark taps through to the Home root',
      (tester) async {
    // Logo-links-home through the real rail: the brand mark at the top of the
    // rail is a bare BrandLogo with its own InkWell — no plate anywhere in the
    // app since v3 — so pin that the tap surface survived the plate's removal.
    final container = await pumpApp(tester);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.trips.index);

    await tester.tap(find.descendant(
        of: find.byType(NavigationRail), matching: find.byType(BrandLogo)));
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.home.index);
  });

  testWidgets('the rail mark sits on the app-bar wordmark centre line',
      (tester) async {
    // The rose lives in the rail and the wordmark in the content area's app
    // bar — different subtrees, same window y = 0, and nothing structural
    // holds them on one line. Pin the two against EACH OTHER, not against a
    // literal, so this still catches a regression if the toolbar height moves.
    await pumpApp(tester);

    final mark = tester.getCenter(find.descendant(
        of: find.byType(NavigationRail), matching: find.byType(BrandLogo)));
    final wordmark = tester.getCenter(find.descendant(
        of: find.byType(AppBar), matching: find.text(AppInfo.name)));

    expect(mark.dy, wordmark.dy);
    expect(mark.dy, kToolbarHeight / 2);
  });

  testWidgets('re-tapping the active Trips tab pops it to root',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });
}
