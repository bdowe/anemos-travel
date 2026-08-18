import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/app_routes.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/pending_prompt_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/pending_prompt.dart';

import 'support/url_sync_fakes.dart';

/// The ONE consume point for a landing prompt
/// (specs/landing-prompt-handoff): fires exactly when the session becomes
/// signed-in AND onboarded, prefills the Agent composer draft, preselects the
/// Plan tab unless a deep link chose a destination, and never replays.

class _RecordingAnalytics implements AnalyticsApiService {
  final consumed = <String>[];

  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<void> recordPendingPromptConsumed({required String surface}) {
    consumed.add(surface);
    return Future.value();
  }

  @override
  Future<void> recordLandingPromptSubmitted(
          {required String surface, String? kind}) =>
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

UserModel _onboardingUser() => UserModel(
      id: 'user-2',
      email: 'new@example.com',
      displayName: 'New',
      createdAt: DateTime(2026, 1, 1),
      needsOnboarding: true,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PendingPromptStore.resetMemoryForTest();
  });

  /// Pumps a minimal tree that keeps [pendingPromptResumeProvider] alive from
  /// the first frame, exactly as TravelRoutePlannerApp's watch does.
  Future<(ProviderContainer, FakeAuthNotifier, _RecordingAnalytics)> pumpHost(
    WidgetTester tester, {
    UserModel? user,
  }) async {
    final auth = FakeAuthNotifier(user);
    final analytics = _RecordingAnalytics();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => auth),
        analyticsApiServiceProvider.overrideWithValue(analytics),
        urlReporterProvider.overrideWithValue((_) {}),
      ],
      child: Consumer(builder: (context, ref, _) {
        ref.watch(pendingPromptResumeProvider);
        return const MaterialApp(home: SizedBox());
      }),
    ));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(Consumer)));
    return (container, auth, analytics);
  }

  String draftText(ProviderContainer c) =>
      c.read(chatDraftProvider(chatDraftKeyFor(null))).text;

  testWidgets('sign-in transition consumes: draft prefilled, Plan tab '
      'selected, consume recorded', (tester) async {
    await const PendingPromptStore().save('A week in Rome', sourceId: 'rome');
    final (container, auth, analytics) = await pumpHost(tester);

    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), 'A week in Rome');
    expect(container.read(navIndexProvider), AppTab.plan.index);
    expect(analytics.consumed, ['card']);
    // Single use: nothing left for a later transition.
    expect(await const PendingPromptStore().take(), isNull);
  });

  testWidgets('already-eligible cold boot consumes via the post-frame check',
      (tester) async {
    await const PendingPromptStore().save('Street food in Bangkok');
    final (container, _, analytics) = await pumpHost(tester, user: fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), 'Street food in Bangkok');
    expect(analytics.consumed, ['hero']);
  });

  testWidgets('withheld while needsOnboarding; fires when the quiz completes',
      (tester) async {
    await const PendingPromptStore().save('A week in Rome');
    final (container, auth, _) = await pumpHost(tester);

    auth.signIn(_onboardingUser());
    await tester.pumpAndSettle();
    expect(draftText(container), isEmpty);

    // The quiz finishing (or Skip) flips the flag on the same user.
    auth.signIn(fakeUser());
    await tester.pumpAndSettle();
    expect(draftText(container), 'A week in Rome');
  });

  testWidgets('a boot target keeps its tab; the draft still lands',
      (tester) async {
    await const PendingPromptStore().save('A week in Rome');
    final (container, auth, _) = await pumpHost(tester);
    container
        .read(urlSyncProvider)
        .registerBootTarget(const BootTarget(AppTab.trips, tripId: 't1'));

    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), 'A week in Rome');
    // The deep-linked destination wins the tab.
    expect(container.read(navIndexProvider), isNot(AppTab.plan.index));
  });

  testWidgets('nothing pending: a transition changes nothing', (tester) async {
    final (container, auth, analytics) = await pumpHost(tester);

    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), isEmpty);
    expect(container.read(navIndexProvider), AppTab.home.index);
    expect(analytics.consumed, isEmpty);
  });

  testWidgets('a stale prompt is not applied', (tester) async {
    final tooOld = DateTime.now()
        .toUtc()
        .subtract(PendingPromptStore.maxAge + const Duration(minutes: 1))
        .millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'pending_prompt.text': 'forgotten idea',
      'pending_prompt.saved_at': tooOld,
    });
    final (container, auth, analytics) = await pumpHost(tester);

    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), isEmpty);
    expect(analytics.consumed, isEmpty);
  });

  testWidgets('a pending connector consent defers the consume; the prompt '
      'survives for the next sign-in', (tester) async {
    await const PendingPromptStore().save('A week in Rome');
    // An active connect flow ends in a full-page redirect — consuming now
    // would strand the prompt in the dying page's memory.
    final freshConnect =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'pending_prompt.text': 'A week in Rome',
      'pending_prompt.saved_at': freshConnect,
      'pending_connect.request_token': 'gt_rq_live',
      'pending_connect.saved_at': freshConnect,
    });
    PendingPromptStore.resetMemoryForTest();
    final (container, auth, analytics) = await pumpHost(tester);

    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), isEmpty);
    expect(analytics.consumed, isEmpty);
    // The prompt is still stored for the sign-in after the connect flow.
    expect((await const PendingPromptStore().take())?.text, 'A week in Rome');
  });

  testWidgets('a boot target consumed in a PREVIOUS sign-in cycle does not '
      'suppress the Plan-tab preselect after sign-out', (tester) async {
    final (container, auth, _) = await pumpHost(tester);
    container
        .read(urlSyncProvider)
        .registerBootTarget(const BootTarget(AppTab.trips, tripId: 't1'));

    // Cycle 1: deep-linked sign-in consumes the boot target.
    auth.signIn(fakeUser());
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.trips.index);

    // Cycle 2: sign out, a fresh landing prompt, sign back in — the old
    // deep link must not steal this cycle's tab.
    auth.signOut();
    await tester.pumpAndSettle();
    await const PendingPromptStore().save('A week in Rome');
    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), 'A week in Rome');
    expect(container.read(navIndexProvider), AppTab.plan.index);
  });

  testWidgets('sign-out then a new submit consumes again in the same run',
      (tester) async {
    await const PendingPromptStore().save('first trip');
    final (container, auth, analytics) = await pumpHost(tester);

    auth.signIn(fakeUser());
    await tester.pumpAndSettle();
    expect(draftText(container), 'first trip');

    auth.signOut();
    await tester.pumpAndSettle();
    // A fresh landing submit while signed out…
    await const PendingPromptStore().save('second trip');
    auth.signIn(fakeUser());
    await tester.pumpAndSettle();

    expect(draftText(container), 'second trip');
    expect(analytics.consumed, hasLength(2));
  });
}
