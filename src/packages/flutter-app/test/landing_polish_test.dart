import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/widgets/section_header.dart';

import 'support/l10n_test_app.dart';

class _NoopAnalytics implements AnalyticsApiService {
  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<void> recordLandingViewed() => Future.value();

  @override
  Future<void> recordBookingLinkClicked({
    String? tripId,
    String? todoKey,
    String? provider,
    String? surface,
    String? kind,
  }) =>
      Future.value();

  @override
  Future<void> recordItineraryItemAdded({
    required String tripId,
    required String source,
  }) =>
      Future.value();
}

Future<void> _pump(
  WidgetTester tester, {
  required Size surface,
  Locale? locale,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      analyticsApiServiceProvider.overrideWithValue(_NoopAnalytics())
    ],
    child: localizedTestApp(home: const LandingScreen(), locale: locale),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(LandingScreen.resetViewRecordedForTest);

  testWidgets('overflow floor: both hero CTAs fit above the fold at 320x568',
      (tester) async {
    await _pump(tester, surface: const Size(320, 568));
    expect(tester.takeException(), isNull);

    // Hero CTA (the first 'Get started' in tree order) is fully visible
    // without scrolling — the acquisition-surface guarantee.
    final primary = find.widgetWithText(FilledButton, 'Get started').first;
    expect(tester.getBottomLeft(primary).dy, lessThanOrEqualTo(568));
    final secondary =
        find.widgetWithText(TextButton, 'I already have an account');
    expect(tester.getBottomLeft(secondary).dy, lessThanOrEqualTo(568));
  });

  testWidgets('overflow floor: Spanish landing renders clean at 360x690',
      (tester) async {
    await _pump(tester,
        surface: const Size(360, 690), locale: const Locale('es'));
    expect(tester.takeException(), isNull);

    expect(find.text('Empezar'), findsWidgets);
    final primary = find.widgetWithText(FilledButton, 'Empezar').first;
    expect(tester.getBottomLeft(primary).dy, lessThanOrEqualTo(690));
  });

  testWidgets('desktop: content stays capped by PageContainer at 1200x900',
      (tester) async {
    await _pump(tester, surface: const Size(1200, 900));
    expect(tester.takeException(), isNull);

    // Every CTA (hero + trailing) stays within the 700px content column.
    for (final button in find.byType(FilledButton).evaluate()) {
      expect(tester.getSize(find.byWidget(button.widget)).width,
          lessThanOrEqualTo(700));
    }
    // Features title uses the shared SectionHeader.
    expect(find.byType(SectionHeader), findsOneWidget);
    // Footer legal links use the shared legal strings.
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Service'), findsOneWidget);
  });
}
