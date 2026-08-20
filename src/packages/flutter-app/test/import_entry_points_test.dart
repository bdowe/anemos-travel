import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/agent_screen.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/screens/import_trip_screen.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/url_sync_fakes.dart';

/// Every "Import from AI chat" entry point funnels through
/// openImportOnTripsTab: the import screen opens on the TRIPS tab (whose
/// stack the post-import trip detail must land on), the URL reports /import,
/// and back lands on the trips list — regardless of which tab hosted the
/// entry (specs/import-trip-from-ai-chat).
///
/// Finder discipline: the shell's IndexedStack keeps all three tabs mounted,
/// and with an empty account every tab carries the same import label — scope
/// every find/tap to its host screen, never a bare byType/text.
class _EmptyTripsApi extends FakeTripsApiService {
  _EmptyTripsApi() : super(fakeTrip('unused'));

  @override
  Future<List<Trip>> listTrips() async => const [];
}

void main() {
  late List<String> reports;

  Future<ProviderContainer> pumpApp(WidgetTester tester,
      {TripsApiService? api}) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(api ?? FakeTripsApiService(fakeTrip('t1'))),
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

  Finder importLabelIn(Type screen) => find.descendant(
      of: find.byType(screen), matching: find.text('Import from AI chat'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('agent empty-state button opens import on the Trips tab',
      (tester) async {
    final container = await pumpApp(tester);

    container.read(navIndexProvider.notifier).state = AppTab.plan.index;
    await tester.pumpAndSettle();
    // ensureVisible, not a bare tap: the intro is one scrollable block now, and
    // in the 800x600 test surface the fallback font wraps the heading and the
    // paragraph far wider than Inter does, which pushes this chip past the
    // fold. tap() on an off-screen target only WARNS — the test would go green
    // while selecting nothing. What this test is about is where the chip goes,
    // not whether the test font happens to leave it above the fold.
    await tester.ensureVisible(importLabelIn(AgentScreen));
    await tester.pumpAndSettle();
    await tester.tap(importLabelIn(AgentScreen));
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(ImportTripScreen), findsOneWidget);
    expect(reports.last, '/import');

    // Back lands on the trips LIST, not the Plan tab that hosted the entry.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ImportTripScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });

  testWidgets('new-user hero import line opens import on the Trips tab',
      (tester) async {
    final container = await pumpApp(tester, api: _EmptyTripsApi());

    // Empty account → Home shows the photo hero, which carries the import
    // line under its chips.
    expect(importLabelIn(HomeScreen), findsOneWidget);

    // The line sits below the 600px test viewport's fold — scroll it in.
    await tester.ensureVisible(importLabelIn(HomeScreen));
    await tester.pumpAndSettle();
    await tester.tap(importLabelIn(HomeScreen));
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(ImportTripScreen), findsOneWidget);
    expect(reports.last, '/import');
  });

  testWidgets('trips-list app-bar icon still opens import via the helper',
      (tester) async {
    final container = await pumpApp(tester);

    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(TripsListScreen),
        matching: find.byIcon(Icons.content_paste_go)));
    await tester.pumpAndSettle();

    expect(find.byType(ImportTripScreen), findsOneWidget);
    expect(reports.last, '/import');
    expect(container.read(navIndexProvider), AppTab.trips.index);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });
}
