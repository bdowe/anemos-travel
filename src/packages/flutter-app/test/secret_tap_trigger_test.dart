import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/easter_egg_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/utils/secret_tap_counter.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';
import 'package:travel_route_planner/widgets/gradient_app_bar.dart';
import 'package:travel_route_planner/widgets/rick_roll_overlay.dart';

import 'support/url_sync_fakes.dart';

/// The touch way into the easter egg: seven taps on the brand. The timing
/// rules are covered exhaustively in `secret_tap_counter_test.dart`; what is
/// proved here is the wiring, on the two screens that differ — one where the
/// brand is a button and one where it is not.
///
/// The overlay animates forever while it is up: never `pumpAndSettle` with it
/// on screen, and always dismiss before a test ends so its auto-dismiss timer
/// is cancelled.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // A frozen clock, so seven taps are always "in quick succession" no matter
  // how loaded the machine running the test is.
  final frozen = DateTime.utc(2026, 1, 1, 12);

  Future<void> pumpApp(WidgetTester tester, {required bool signedIn}) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rickRollProvider
              .overrideWith((ref) => RickRollNotifier(now: () => frozen)),
          authProvider.overrideWith(
              (ref) => FakeAuthNotifier(signedIn ? fakeUser() : null)),
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
  }

  /// The app bar's brand specifically. Scoped, because the landing page also
  /// renders a large [BrandWordmark] in its hero — a bare `byType().first`
  /// finds that one, which carries no trigger and is not what ships on every
  /// screen. `hitTestable` then picks the visible app bar out of the three the
  /// shell keeps mounted in its IndexedStack.
  Finder appBarBrand() => find
      .descendant(
        of: find.byType(GradientAppBar),
        matching: find.byType(BrandWordmark),
      )
      .hitTestable();

  Future<void> tapBrand(WidgetTester tester, int times) async {
    for (var i = 0; i < times; i++) {
      await tester.tap(appBarBrand().first);
      await tester.pump();
    }
  }

  testWidgets('seven taps on the brand roll the site, signed in',
      (tester) async {
    await pumpApp(tester, signedIn: true);
    expect(find.byType(RickRollOverlay), findsNothing);

    await tapBrand(tester, kSecretTapCount - 1);
    expect(find.byType(RickRollOverlay), findsNothing,
        reason: 'six taps must not be enough');

    await tapBrand(tester, 1);
    expect(find.byType(RickRollOverlay), findsOneWidget);

    await tester.tapAt(const Offset(40, 400));
    await tester.pump();
    expect(find.byType(RickRollOverlay), findsNothing);
  });

  testWidgets('it also works where the brand is not a button', (tester) async {
    // Signed out, the brand has no onTap at all — no InkWell, no button
    // semantics. The Listener is deliberately outside that branch, because
    // the landing page is exactly where somebody idly prodding the logo is
    // standing. Tapping through the InkWell is what this proves is NOT
    // required.
    await pumpApp(tester, signedIn: false);
    expect(appBarBrand(), findsOneWidget);
    // Ancestors of the brand, not of the app bar — the bar's own language and
    // sign-in actions are InkWells and always were.
    expect(
      find.ancestor(of: appBarBrand(), matching: find.byType(InkWell)),
      findsNothing,
      reason: 'the signed-out brand must still not be a button',
    );

    await tapBrand(tester, kSecretTapCount);
    expect(find.byType(RickRollOverlay), findsOneWidget);

    await tester.tapAt(const Offset(40, 400));
    await tester.pump();
    expect(find.byType(RickRollOverlay), findsNothing);
  });
}
