import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/app_shell.dart';
import 'package:travel_route_planner/utils/konami_detector.dart';
import 'package:travel_route_planner/widgets/konami_listener.dart';
import 'package:travel_route_planner/widgets/rick_roll_overlay.dart';

import 'support/l10n_test_app.dart';
import 'support/url_sync_fakes.dart';

/// The Konami-code easter egg, from the two angles that can break something
/// real: it has to reach the whole app without remounting any of it, and it
/// has to leave every other key handler in the app alone.
///
/// Audio resolves to `rick_roll_audio_stub.dart` on the VM, so these run
/// silent. Note that the overlay animates forever while it is up — never
/// `pumpAndSettle` with it on screen, and always dismiss before a test ends so
/// its auto-dismiss timer is cancelled.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> enterKonamiCode(WidgetTester tester) async {
    for (final key in kKonamiCode) {
      await tester.sendKeyEvent(key);
    }
    await tester.pump();
  }

  testWidgets('the code rolls the site, and Escape ends it', (tester) async {
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

    expect(find.byType(RickRollOverlay), findsNothing);
    // The app's own element, captured before the trigger. The overlay is a
    // sibling appended after this in a fixed-length Stack, so the app must
    // come through untouched — a remount here would be the trip page losing
    // every unsaved draft the moment somebody pressed Up.
    final shell = tester.element(find.byType(AppShell));

    await enterKonamiCode(tester);
    expect(find.byType(RickRollOverlay), findsOneWidget);
    expect(tester.element(find.byType(AppShell)), same(shell));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(RickRollOverlay), findsNothing);
    expect(tester.element(find.byType(AppShell)), same(shell));
  });

  testWidgets('no key is swallowed — except Escape while rolling',
      (tester) async {
    final seen = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      ProviderScope(
        child: localizedTestApp(
          home: KonamiListener(
            child: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent) seen.add(event.logicalKey);
                return KeyEventResult.ignored;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await enterKonamiCode(tester);

    // Every key of the code still reached the focus tree. This is the whole
    // reason the detector hangs off HardwareKeyboard and returns false: a
    // focused text field keeps its arrow keys for the caret, and B and A keep
    // typing letters.
    expect(seen, kKonamiCode);
    expect(find.byType(RickRollOverlay), findsOneWidget);

    seen.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    // The one documented exception. Escape is consumed while the roll is up,
    // so escaping the joke cannot also close the fullscreen map or the refine
    // chat panel sitting underneath it.
    expect(seen, isEmpty);
    expect(find.byType(RickRollOverlay), findsNothing);
  });

  testWidgets('a tap anywhere ends it', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: localizedTestApp(
          home: const KonamiListener(child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    await enterKonamiCode(tester);
    expect(find.byType(RickRollOverlay), findsOneWidget);

    await tester.tapAt(const Offset(40, 300));
    await tester.pump();
    expect(find.byType(RickRollOverlay), findsNothing);
  });
}
