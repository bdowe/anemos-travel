import 'package:flutter/widgets.dart';
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

import 'support/url_sync_fakes.dart';

/// The shell keeps every tab mounted in an IndexedStack (state, scroll,
/// GlobalKeys survive tab switches) but hidden tabs must not keep animating:
/// each child is wrapped in a TickerMode enabled only for the active index,
/// so an open TripDetailScreen on a background tab freezes its tickers
/// instead of burning frames offscreen.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('only the active tab has an enabled TickerMode', (tester) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t1'))),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue((_) {}),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();

    IndexedStack shellStack() => tester.widget<IndexedStack>(find
        .descendant(
            of: find.byType(AppShell), matching: find.byType(IndexedStack))
        .first);
    List<int> enabledIndexes(IndexedStack stack) => [
          for (var i = 0; i < stack.children.length; i++)
            if ((stack.children[i] as TickerMode).enabled) i,
        ];

    var stack = shellStack();
    // Every tab is wrapped; exactly the active one ticks.
    expect(stack.children, everyElement(isA<TickerMode>()));
    expect(enabledIndexes(stack), [stack.index]);

    // Switch tabs: the enabled TickerMode follows the active index and the
    // previous tab's freezes.
    final container = ProviderScope.containerOf(
        tester.element(find.byType(TravelRoutePlannerApp)));
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    await tester.pumpAndSettle();

    stack = shellStack();
    expect(stack.index, AppTab.trips.index);
    expect(enabledIndexes(stack), [AppTab.trips.index]);
  });
}
