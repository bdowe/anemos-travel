import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/alerts_screen.dart';
import 'package:travel_route_planner/screens/app_shell.dart';
import 'package:travel_route_planner/screens/import_trip_screen.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/url_sync_fakes.dart';

/// Boot restore (specs/url-page-persistence): pumping the real app with a
/// deep-link boot URL must land inside the shell on the URL's page — the
/// refresh-doesn't-lose-your-place half of URL persistence.
void main() {
  late FakeAuthNotifier auth;
  late List<String> reports;

  Future<void> pumpApp(
    WidgetTester tester, {
    required String initialUrl,
    UserModel? user,
  }) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = initialUrl;
    auth = FakeAuthNotifier(user);
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
  }

  T read<T>(WidgetTester tester, ProviderListenable<T> provider) =>
      ProviderScope.containerOf(
              tester.element(find.byType(TravelRoutePlannerApp)))
          .read(provider);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('booting /trips/<id> restores trip detail inside the shell',
      (tester) async {
    await pumpApp(tester, initialUrl: '/trips/t1', user: fakeUser());

    expect(find.byType(AppShell), findsOneWidget);
    expect(read(tester, navIndexProvider), AppTab.trips.index);
    final detail =
        tester.widget<TripDetailScreen>(find.byType(TripDetailScreen));
    expect(detail.tripId, 't1');
    expect(reports.last, '/trips/t1');
  });

  testWidgets('the /trip/<id> connector alias opens the trip and normalizes',
      (tester) async {
    await pumpApp(tester, initialUrl: '/trip/t1', user: fakeUser());

    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');
  });

  testWidgets('booting /alerts restores the screen in-shell on the home tab',
      (tester) async {
    await pumpApp(tester, initialUrl: '/alerts', user: fakeUser());

    expect(find.byType(AppShell), findsOneWidget);
    expect(read(tester, navIndexProvider), AppTab.home.index);
    expect(find.byType(AlertsScreen), findsOneWidget);
    expect(reports.last, '/alerts');
  });

  testWidgets('booting /import restores onto the trips tab', (tester) async {
    await pumpApp(tester, initialUrl: '/import', user: fakeUser());

    expect(read(tester, navIndexProvider), AppTab.trips.index);
    expect(find.byType(ImportTripScreen), findsOneWidget);
    expect(reports.last, '/import');
  });

  testWidgets('an unknown path behaves like the plain catch-all',
      (tester) async {
    await pumpApp(tester, initialUrl: '/no-such-page', user: fakeUser());

    expect(find.byType(AppShell), findsOneWidget);
    expect(read(tester, navIndexProvider), AppTab.home.index);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed-out deep link waits on the landing page, then lands',
      (tester) async {
    await pumpApp(tester, initialUrl: '/trips/t1', user: null);

    expect(find.byType(LandingScreen), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    // The bare-boot gate: nothing may rewrite the URL while signed out.
    expect(reports, isEmpty);

    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(find.byType(AppShell), findsOneWidget);
    expect(read(tester, navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');
  });
}
