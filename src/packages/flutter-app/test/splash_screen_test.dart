import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/screens/splash_screen.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';

void main() {
  // The splash animations repeat forever, so these tests use pump() with
  // explicit durations — pumpAndSettle would never settle.
  // "No plate" is no longer asserted here: the plate widget is gone from the
  // app entirely (v3 of the policy in brand_logo.dart), so the compiler pins
  // what an expectation used to. What still needs pinning is the *cut* — the
  // reversed mark is what reads on the Aegean-night field.
  Widget harness({MediaQueryData? mediaQuery, Widget child = const SplashScreen()}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: mediaQuery == null
          ? child
          : MediaQuery(data: mediaQuery, child: child),
    );
  }

  testWidgets('splash floats the bare light mark', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));

    final image = tester.widget<Image>(
      find.descendant(of: find.byType(BrandLogo), matching: find.byType(Image)),
    );
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/anemos_mark_light.png',
    );
  });

  testWidgets('loading signal is the labelled dots, not a Material spinner',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));

    // The redesign replaced the spinner (the one generic-default element on
    // the boot screen) with the breathing dots; the label is the loading
    // state's only text, so losing it would silence the screen for readers.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
  });

  testWidgets('reduced motion stills the pulse and the dots', (tester) async {
    await tester.pumpWidget(
      harness(mediaQuery: const MediaQueryData(disableAnimations: true)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Both repeating controllers must be parked, or the splash animates for
    // exactly the travelers who asked it not to. No scheduled tickers is the
    // observable form of "still" — and it is also what lets this pump settle.
    expect(tester.binding.transientCallbackCount, 0);
  });
}
