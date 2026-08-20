import 'dart:convert';

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
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/live_trip_card.dart';

import 'support/url_sync_fakes.dart';

/// Where a trip opens, and where back puts you afterwards.
///
/// Home's trip cards (LiveTripCard + the "Continue where you left off"
/// recent-trip tile) open the detail on the TRIPS tab via openTripOnTripsTab —
/// the Trips nav item highlights — instead of stacking the detail over Home
/// where the Home button would re-reveal it. That half is unchanged and still
/// pinned here.
///
/// What changed: back now returns to the tab you came FROM. Opened from Home,
/// back lands on Home; opened from the trips list, back lands on the list,
/// exactly as before. The origin rides the route
/// ([TripDetailScreen.entryOrigin]), so a trip opened from the list can never
/// inherit a phantom "came from Home" left behind by an earlier one — the last
/// two cases below are that guarantee.
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

  /// The real nav button. The default 800x600 test surface is at
  /// kRailBreakpoint, so the shell renders a NavigationRail and these taps go
  /// through selectTab — including its re-tap popUntil, which is the one path
  /// that takes the detail off the stack without consulting any PopScope.
  Finder railDestination(String label) => find.descendant(
      of: find.byType(NavigationRail), matching: find.text(label));

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

  testWidgets('live trip card opens on the Trips tab and backs out to Home',
      (tester) async {
    final container = await pumpApp(tester, live: liveTrip('t3'));

    await tester.tap(find.byType(LiveTripCard));
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t3');

    // Back returns to the tab the trip was opened from.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.home.index);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(reports.last, '/');
    // skipOffstage: false because the contract is that the trip is CLOSED, not
    // merely hidden behind the tab switch — the IndexedStack keeps a hidden
    // tab's subtree mounted, so the default finder would report "gone" either
    // way. (_IndexedStackElement.debugVisitOnstageChildren visits only the
    // selected child.)
    expect(find.byType(TripDetailScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('recent trip card opens on the Trips tab and backs out to Home',
      (tester) async {
    seedRecentTrip('t2', 'Lisbon Trip');
    final container = await pumpApp(tester);

    // Scroll it in first. Widget tests load no fonts, so the greeting above
    // this card is set in a fallback face whose glyphs are a full em each —
    // roughly 2.2x the real display face's width (brand_everywhere_test says
    // the same thing about page titles). That pushes the card past the
    // 800x600 test surface whenever the headline tier grows, and tap() on an
    // off-screen target silently misses instead of failing loudly: the
    // assertion below then reads as "navigation is broken" when nothing but
    // the test font's metrics moved. What this test is about is the tap, not
    // the scroll position.
    await tester.ensureVisible(find.text('Lisbon Trip'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lisbon Trip'));
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t2');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.home.index);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(TripDetailScreen, skipOffstage: false), findsNothing);
    expect(reports.last, '/');
  });

  testWidgets('a detail already on the Trips stack is replaced, not stacked',
      (tester) async {
    // Pins openTripOnTripsTab's pre-push reset: nothing may be left underneath
    // the trip you asked for.
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
    expect(container.read(navIndexProvider), AppTab.home.index);
    expect(find.byType(TripDetailScreen, skipOffstage: false), findsNothing);
    expect(reports.last, '/');
  });

  testWidgets('backing out to Home leaves the Trips tab on its list',
      (tester) async {
    // Trips KEEPS its stack (_stackKeepingTabs), so whatever back leaves
    // behind is what the next Trips tap shows. Back means the traveler closed
    // the trip, not that they parked it — otherwise the trip they just backed
    // out of greets them again, and the trips list becomes unreachable in one
    // tap.
    final container = await pumpApp(tester, live: liveTrip('t3'));

    await tester.tap(find.byType(LiveTripCard));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.home.index);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });

  testWidgets('a trip opened from the trips list still backs out to the list',
      (tester) async {
    // The unchanged half: no origin on the route, so back is the ordinary pop
    // it has always been, and the tab never moves.
    final container = await pumpApp(tester);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });

  testWidgets('a Home-opened trip leaves no origin behind for the next one',
      (tester) async {
    // The failure this exists to prevent, and the reason the origin is a field
    // on the route rather than a provider: leave a Home-opened trip by a path
    // that never consults PopScope — selectTab's re-tap popUntil is exactly
    // that path — and then open a trip from the LIST. An ambient origin record
    // would still be sitting there, and this second trip, which the traveler
    // reached from the list, would throw them onto Home on back.
    final container = await pumpApp(tester, live: liveTrip('t3'));

    await tester.tap(find.byType(LiveTripCard));
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsOneWidget);

    // Re-tap the tab we are already on: popUntil(isFirst), no PopScope in the
    // loop, detail gone, still on Trips.
    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsNothing);

    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.trips.index,
        reason: 'this trip was opened from the list, so back stays on Trips');
    expect(find.text('Lisbon long weekend'), findsOneWidget);
    expect(reports.last, '/trips');
  });
}
