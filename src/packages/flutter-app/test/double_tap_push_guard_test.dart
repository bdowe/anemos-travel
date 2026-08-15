import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/navigation/app_nav.dart';

/// The double-tap guard (isTopRoute / pushOnce, app_nav.dart): two pushes
/// leave a duplicate screen stacked under an opaque one, so it looks fine
/// until "back" lands on the page you were already looking at.
///
/// Both cases below pop once and assert the destination is GONE — the stacked
/// duplicate is invisible to a finder while it sits under an opaque route, so
/// "exactly one on screen" would pass either way.
///
/// Deliberately NOT tested through a real double tap on a trip card: Flutter's
/// own `_cancelActivePointers` absorbs the second pointer when a route changes
/// between frames, so such a test passes with the guard removed and would pin
/// nothing. What it does not cover — a push after an await — is case two, and
/// that is the shape this app actually reaches (connect_app_screen `_signIn`).
void main() {
  Widget harness(GlobalKey<NavigatorState> navKey, VoidCallback onPressed) =>
      MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: Center(
            child: TextButton(onPressed: onPressed, child: const Text('go')),
          ),
        ),
      );

  Route<void> pushedRoute() =>
      MaterialPageRoute<void>(builder: (_) => const Text('pushed'));

  testWidgets('pushOnce drops a second push, and does not wedge later ones',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    late BuildContext ctx;
    await tester.pumpWidget(harness(navKey, () {
      // Twice from one handler: the guard's job without any dependence on
      // gesture timing.
      pushOnce(ctx, pushedRoute());
      pushOnce(ctx, pushedRoute());
    }));
    ctx = tester.element(find.text('go'));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsNothing,
        reason: 'a second route was stacked underneath');
    expect(find.text('go'), findsOneWidget);

    // Not sticky: the next tap pushes normally.
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);
  });

  testWidgets('a push after an await is guarded too', (tester) async {
    // The case Flutter's pointer-absorb cannot reach: nothing has changed in
    // the route stack at tap time, so both taps are delivered, and only the
    // guard stops the second handler from pushing when it wakes up.
    final navKey = GlobalKey<NavigatorState>();
    final gate = Completer<void>();
    late BuildContext ctx;
    await tester.pumpWidget(harness(navKey, () async {
      await gate.future;
      pushOnce(ctx, pushedRoute());
    }));
    ctx = tester.element(find.text('go'));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.tap(find.text('go'));
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsNothing,
        reason: 'both parked handlers pushed');
    expect(find.text('go'), findsOneWidget);
  });
}
