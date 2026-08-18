import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/screens/auth_screen.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/pending_prompt.dart';
import 'package:travel_route_planner/widgets/destination_suggestion_card.dart';

import 'support/l10n_test_app.dart';
import 'support/url_sync_fakes.dart';

/// The REAL landing handoff (no provider override): submitting the hero
/// prompt persists it BEFORE navigation, records the anonymous funnel event,
/// and continues into sign-up (specs/landing-prompt-handoff).

class _RecordingAnalytics implements AnalyticsApiService {
  final submitted = <({String surface, String? kind})>[];

  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<void> recordLandingPromptSubmitted(
      {required String surface, String? kind}) {
    submitted.add((surface: surface, kind: kind));
    return Future.value();
  }

  @override
  Future<void> recordPendingPromptConsumed({required String surface}) =>
      Future.value();

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

  @override
  Future<void> recordLegsParityMismatch(
          {required String tripId, required List<String> details}) =>
      Future.value();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PendingPromptStore.resetMemoryForTest();
    LandingScreen.resetViewRecordedForTest();
  });

  Future<_RecordingAnalytics> pumpLanding(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final analytics = _RecordingAnalytics();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        analyticsApiServiceProvider.overrideWithValue(analytics),
        // The push lands on the real AuthScreen; keep its session and SSO
        // availability deterministic and offline.
        authProvider.overrideWith((ref) => FakeAuthNotifier(null)),
        googleSsoAvailableProvider.overrideWith((ref) async => false),
        appleSsoAvailableProvider.overrideWith((ref) async => false),
        ...overrides,
      ],
      child: localizedTestApp(home: const LandingScreen()),
    ));
    await tester.pumpAndSettle();
    return analytics;
  }

  testWidgets('hero submit: store written (trimmed), event recorded, '
      'sign-up pushed', (tester) async {
    final analytics = await pumpLanding(tester);

    await tester.enterText(
        find.byKey(const Key('landing-prompt-input')), '  A week in Rome  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('landing-prompt-submit')));
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(
        tester.widget<AuthScreen>(find.byType(AuthScreen)).initialIsLogin,
        isFalse);
    expect(analytics.submitted,
        [(surface: 'hero', kind: null)]);
    final stored = await const PendingPromptStore().take();
    expect(stored?.text, 'A week in Rome');
    expect(stored?.sourceId, isNull);
  });

  testWidgets('destination card: store written with the slug, card event '
      'recorded, sign-up pushed', (tester) async {
    final analytics = await pumpLanding(tester,
        overrides: [
          // Identity order so the first card is pool[0] deterministically.
          suggestionOrderProvider.overrideWithValue(
              () => List.generate(suggestionPool.length, (i) => i)),
        ]);

    final card = find.byType(DestinationSuggestionCard).first;
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final prompt = tester.widget<DestinationSuggestionCard>(card).prompt;

    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(analytics.submitted, hasLength(1));
    expect(analytics.submitted.single.surface, 'card');
    expect(analytics.submitted.single.kind, 'paris');
    final stored = await const PendingPromptStore().take();
    expect(stored?.text, prompt);
    expect(stored?.sourceId, 'paris');
  });
}
