import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/screens/splash_screen.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';

void main() {
  // The splash pulse controller repeats forever, so these tests use pump()
  // with explicit durations — pumpAndSettle would never settle.
  testWidgets('splash floats the bare light mark — no badge plate',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(BrandBadge), findsNothing);

    final image = tester.widget<Image>(
      find.descendant(of: find.byType(BrandLogo), matching: find.byType(Image)),
    );
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/anemos_mark_light.png',
    );
  });

  testWidgets('splash keeps the progress spinner', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
