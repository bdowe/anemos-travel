import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';

import 'support/l10n_test_app.dart';

/// Counts landing-view records instead of hitting the network.
class _CountingAnalytics implements AnalyticsApiService {
  @override
  Future<void> recordLegsParityMismatch(
          {required String tripId, required List<String> details}) =>
      Future.value();

  int landingViews = 0;

  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<void> recordLandingViewed() {
    landingViews++;
    return Future.value();
  }

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

Widget _harness(_CountingAnalytics analytics) {
  return ProviderScope(
    overrides: [analyticsApiServiceProvider.overrideWithValue(analytics)],
    child: localizedTestApp(home: const LandingScreen()),
  );
}

void main() {
  setUp(LandingScreen.resetViewRecordedForTest);

  testWidgets('landing screen records landing_viewed once per app session',
      (tester) async {
    final analytics = _CountingAnalytics();
    await tester.pumpWidget(_harness(analytics));
    expect(analytics.landingViews, 1);

    // Rebuilds don't re-record.
    await tester.pumpWidget(_harness(analytics));
    expect(analytics.landingViews, 1);

    // Nor does a fresh LandingScreen instance later in the same session
    // (e.g. returning to the landing page after signing out).
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_harness(analytics));
    expect(analytics.landingViews, 1);
  });

  testWidgets('an analytics failure never breaks the landing page',
      (tester) async {
    final analytics = _ThrowingAnalytics();
    await tester.pumpWidget(ProviderScope(
      overrides: [analyticsApiServiceProvider.overrideWithValue(analytics)],
      child: localizedTestApp(home: const LandingScreen()),
    ));
    expect(find.text('Where to next?'), findsOneWidget);
  });
}

class _ThrowingAnalytics implements AnalyticsApiService {
  @override
  Future<void> recordLegsParityMismatch(
          {required String tripId, required List<String> details}) =>
      Future.value();

  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<void> recordLandingViewed() => throw Exception('analytics down');

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
