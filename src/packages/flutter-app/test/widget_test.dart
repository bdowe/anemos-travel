import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/screens/splash_screen.dart';

void main() {
  testWidgets('App starts without crashing', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: TravelRoutePlannerApp()));

    // The app builds its MaterialApp shell. On the first frame the AuthGate
    // shows the boot splash while the stored session is checked (no network in
    // the test env), then routes to sign-in/home — so we assert the shell and
    // the splash route build cleanly, not any screen's internals (the splash's
    // own anatomy is splash_screen_test's job).
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}