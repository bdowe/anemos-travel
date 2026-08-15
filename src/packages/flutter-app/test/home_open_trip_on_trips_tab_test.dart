import 'dart:convert';

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
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/live_trip_card.dart';

import 'support/url_sync_fakes.dart';

/// Home's trip cards (LiveTripCard + the "Continue where you left off"
/// recent-trip tile) open the detail on the TRIPS tab via openTripOnTripsTab
/// — the Trips nav item highlights and back lands on the trips list — instead
/// of stacking the detail over Home where the Home button would re-reveal it.
void main() {
  late List<String> reports;

  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Trip liveTrip(String id) => Trip(
        id: id,
        title: 'Athens Trip',
        startDate: iso(DateTime.now().subtract(const Duration(days: 1))),
        endDate: iso(DateTime.now().add(const Duration(days: 1))),
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
      );

  /// Seeds the persisted recent-trip snapshot the way the detail screen
  /// records it (recent_trip_provider storage format, keyed by user).
  void seedRecentTrip(String tripId, String title) {
    SharedPreferences.setMockInitialValues({
      'recent_trip.user-1': jsonEncode({
        'id': tripId,
        'title': title,
        'status': 'planned',
      }),
    });
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester,
      {Trip? live}) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t1'))),
          liveTripProvider.overrideWithValue(live),
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

  testWidgets('live trip card opens the detail on the Trips tab',
      (tester) async {
    final container = await pumpApp(tester, live: liveTrip('t3'));

    await tester.tap(find.byType(LiveTripCard));
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t3');

    // Back lands on the trips LIST, not Home.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });

  testWidgets('recent trip card opens the detail on the Trips tab',
      (tester) async {
    seedRecentTrip('t2', 'Lisbon Trip');
    final container = await pumpApp(tester);

    await tester.tap(find.text('Lisbon Trip'));
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t2');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(reports.last, '/trips');
  });

  testWidgets('a detail already on the Trips stack is replaced, not stacked',
      (tester) async {
    // Pins openTripOnTripsTab's pre-push popUntil: back must land on the
    // trips list, never on a previously-open detail left underneath.
    final container = await pumpApp(tester, live: liveTrip('t3'));

    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(reports.last, '/trips/t1');

    container.read(navIndexProvider.notifier).state = AppTab.home.index;
    await tester.pumpAndSettle();

    await tester.tap(find.byType(LiveTripCard));
    // One frame, no settling: the reset and the push are both instant, so on
    // the frame the Trips tab appears there is exactly ONE detail on it. Both
    // steps run while that tab is still hidden, where the shell freezes
    // tickers (app_shell.dart) — animated, they would park and then replay
    // together, the trip you had open sliding out from under the one you
    // asked for.
    await tester.pump();
    expect(find.byType(TripDetailScreen, skipOffstage: false), findsOneWidget,
        reason: 'the previously-open trip must be gone, not sliding out');
    expect(
        tester
            .widget<TripDetailScreen>(
                find.byType(TripDetailScreen, skipOffstage: false))
            .tripId,
        't3');

    await tester.pumpAndSettle();
    expect(reports.last, '/trips/t3');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });
}
