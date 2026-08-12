import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/url_sync_fakes.dart';

/// Nav buttons always land on the page they name (selectTab): selecting a tab
/// resets that tab's stack to its root, so a trip detail left open on the
/// Trips tab can never greet the user on the next Trips tap. The default
/// 800x600 test surface is at kRailBreakpoint, so the NavigationRail renders
/// and taps go through the real nav-button path.
void main() {
  late List<String> reports;

  Finder railDestination(String label) => find.descendant(
      of: find.byType(NavigationRail), matching: find.text(label));

  Future<void> pumpApp(WidgetTester tester) async {
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
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('switching tabs via nav buttons resets the destination to root',
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
    final reportsAfterHome = reports.length;

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
    // Pop-before-switch: the detail's didPop drains while Home is still the
    // active tab, so the stale '/trips/t1' never reaches the address bar.
    expect(reports.sublist(reportsAfterHome), isNot(contains('/trips/t1')));
  });

  testWidgets('re-tapping the active tab still pops it to root',
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
