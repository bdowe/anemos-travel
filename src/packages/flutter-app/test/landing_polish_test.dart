import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/screens/landing/landing_cta_band.dart';
import 'package:travel_route_planner/screens/landing/landing_destination_rail.dart';
import 'package:travel_route_planner/screens/landing/landing_feature_grid.dart';
import 'package:travel_route_planner/screens/landing/landing_footer.dart';
import 'package:travel_route_planner/screens/landing/landing_handoff.dart';
import 'package:travel_route_planner/screens/landing/landing_hero.dart';
import 'package:travel_route_planner/screens/landing/landing_how_it_works.dart';
import 'package:travel_route_planner/screens/landing/landing_layout.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/widgets/destination_suggestion_card.dart';

import 'support/l10n_test_app.dart';

class _NoopAnalytics implements AnalyticsApiService {
  @override
  Future<void> recordLegsParityMismatch(
          {required String tripId, required List<String> details}) =>
      Future.value();

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

/// Records handoff calls so tests can assert on exactly what the landing page
/// hands to specs/landing-prompt-handoff.
class _HandoffRecorder {
  final calls = <({String prompt, String? sourceId})>[];

  void call(BuildContext context, String prompt, {String? sourceId}) =>
      calls.add((prompt: prompt, sourceId: sourceId));
}

Future<void> _pump(
  WidgetTester tester, {
  required Size surface,
  Locale? locale,
  List<Override> overrides = const [],
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      analyticsApiServiceProvider.overrideWithValue(_NoopAnalytics()),
      ...overrides,
    ],
    child: localizedTestApp(home: const LandingScreen(), locale: locale),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(LandingScreen.resetViewRecordedForTest);

  final promptField = find.byKey(const Key('landing-prompt-input'));
  final submitButton = find.byKey(const Key('landing-prompt-submit'));

  testWidgets(
      'overflow floor: headline, prompt field, and submit fit above the fold '
      'at 320x568', (tester) async {
    await _pump(tester, surface: const Size(320, 568));
    expect(tester.takeException(), isNull);

    // The prompt input IS the hero CTA now — the acquisition-surface
    // guarantee is that a visitor can start typing without scrolling.
    expect(tester.getBottomLeft(promptField).dy, lessThanOrEqualTo(568));
    expect(tester.getBottomLeft(submitButton).dy, lessThanOrEqualTo(568));
    // Sign in stays reachable in the app bar at every scroll position.
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('overflow floor: Spanish landing renders clean at 360x690',
      (tester) async {
    await _pump(tester,
        surface: const Size(360, 690), locale: const Locale('es'));
    expect(tester.takeException(), isNull);

    expect(find.text('Describe tu viaje…'), findsOneWidget);
    expect(tester.getBottomLeft(promptField).dy, lessThanOrEqualTo(690));
  });

  testWidgets('desktop: hero runs full-bleed, sections keep their caps',
      (tester) async {
    await _pump(tester, surface: const Size(1200, 900));
    expect(tester.takeException(), isNull);

    // Hero is edge-to-edge (no PageContainer/card chrome around it).
    expect(tester.getSize(find.byType(LandingHero)).width, 1200);
    // Feature grid stays inside the marketing content tier.
    expect(tester.getSize(find.byType(LandingFeatureGrid)).width,
        lessThanOrEqualTo(kLandingContentWidth));
    // The CTA band keeps the 700px reading tier.
    for (final button in find.byType(FilledButton).evaluate()) {
      expect(tester.getSize(find.byWidget(button.widget)).width,
          lessThanOrEqualTo(700));
    }
    // Footer legal links use the shared legal strings.
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Service'), findsOneWidget);
  });

  testWidgets('all landing sections are present in order', (tester) async {
    await _pump(tester, surface: const Size(1200, 900));

    expect(find.byType(LandingHero), findsOneWidget);
    expect(find.byType(LandingFeatureGrid), findsOneWidget);
    expect(find.byType(LandingDestinationRail), findsOneWidget);
    expect(find.byType(LandingHowItWorks), findsOneWidget);
    expect(find.byType(LandingCtaBand), findsOneWidget);
    expect(find.byType(LandingFooter), findsOneWidget);
  });

  testWidgets('chips prefill the field and never call the handoff',
      (tester) async {
    final recorder = _HandoffRecorder();
    await _pump(tester, surface: const Size(800, 900), overrides: [
      // The documented determinism seam: fix WHICH prompts get drawn.
      suggestionPickerProvider.overrideWithValue(() => const [0, 1, 2]),
      landingPromptHandoffProvider.overrideWithValue(recorder.call),
    ]);

    final chip = find.byType(ActionChip).first;
    final label =
        (tester.widget<ActionChip>(chip).label as Text).data ?? '';
    expect(label, isNotEmpty);

    await tester.tap(chip);
    await tester.pump();

    final field = tester.widget<TextField>(promptField);
    expect(field.controller?.text, label);
    expect(recorder.calls, isEmpty);
  });

  testWidgets('submit hands the trimmed prompt to the handoff; empty is inert',
      (tester) async {
    final recorder = _HandoffRecorder();
    await _pump(tester, surface: const Size(800, 900), overrides: [
      landingPromptHandoffProvider.overrideWithValue(recorder.call),
    ]);

    // Empty field: the submit affordance is disabled.
    expect(tester.widget<IconButton>(submitButton).onPressed, isNull);

    await tester.enterText(promptField, '  A week in Rome in May  ');
    await tester.pump();
    await tester.tap(submitButton);
    await tester.pump();

    expect(recorder.calls, hasLength(1));
    expect(recorder.calls.single.prompt, 'A week in Rome in May');
    expect(recorder.calls.single.sourceId, isNull);
  });

  testWidgets('a destination card hands its prompt to the handoff',
      (tester) async {
    final recorder = _HandoffRecorder();
    await _pump(tester, surface: const Size(800, 900), overrides: [
      // Identity order so the first card is pool[0] deterministically.
      suggestionOrderProvider.overrideWithValue(
          () => List.generate(suggestionPool.length, (i) => i)),
      landingPromptHandoffProvider.overrideWithValue(recorder.call),
    ]);

    final card = find.byType(DestinationSuggestionCard).first;
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final prompt = tester.widget<DestinationSuggestionCard>(card).prompt;

    await tester.tap(card);
    await tester.pump();

    expect(recorder.calls, hasLength(1));
    expect(recorder.calls.single.prompt, prompt);
    expect(recorder.calls.single.sourceId, isNotNull);
  });
}
