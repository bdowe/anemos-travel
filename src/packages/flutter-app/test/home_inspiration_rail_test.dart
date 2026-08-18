import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/destination_suggestion_card.dart';
import 'package:travel_route_planner/widgets/home_inspiration_rail.dart';
import 'package:travel_route_planner/widgets/random_suggestions.dart';

import 'support/l10n_test_app.dart';

/// The "Somewhere new" rail's placement contract: inspiration fills the gap
/// only when there is nothing to continue — no live trip and no continue
/// card — and a card tap SENDS its prompt into the Plan tab (Home's one-tap
/// contract; the landing rail hands off instead).
class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

  @override
  void clearError() => state = state.copyWith(clearError: true);

  @override
  Future<bool> login(String email, String password) async => false;

  @override
  Future<bool> register(String email, String password,
          {String? displayName}) async =>
      false;

  @override
  Future<void> completeOnboarding() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<void> signOutLocally() async {}

  @override
  void setUser(UserModel user) {}

  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

/// Records sendMessage calls instead of streaming; no network.
class _RecordingPlanNotifier extends PlanNotifier {
  final List<(String, String?)> sent = [];

  _RecordingPlanNotifier() : super(PlanService('http://unused'), ApiClient());

  @override
  Future<void> sendMessage(String text,
      {String? displayLabel,
      List<PlanAttachment> attachments = const []}) async {
    sent.add((text, displayLabel));
  }
}

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Brian',
      createdAt: DateTime(2026, 1, 1),
    );

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Trip _liveTrip() => Trip(
      id: 't1',
      title: 'Athens Trip',
      startDate: _iso(DateTime.now().subtract(const Duration(days: 1))),
      endDate: _iso(DateTime.now().add(const Duration(days: 1))),
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

ChatSessionSummary _chat(String id, String title) => ChatSessionSummary(
      chatId: id,
      title: title,
      preview: 'Thinking about a week of island hopping.',
      messageCount: 4,
      createdAt: '2026-07-01T10:00:00Z',
      updatedAt: '2026-07-02T10:00:00Z',
    );

void main() {
  late ProviderContainer container;
  late _RecordingPlanNotifier plan;

  Future<void> pumpHome(
    WidgetTester tester, {
    Trip? liveTrip,
    List<ChatSessionSummary> chats = const [],
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    plan = _RecordingPlanNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
          liveTripProvider.overrideWithValue(liveTrip),
          resumableChatsProvider.overrideWith((ref) async => chats),
          planProvider.overrideWith((ref) => plan),
          // Natural pool order so the first (visible) card is a known one.
          suggestionOrderProvider.overrideWithValue(
              () => List<int>.generate(suggestionPool.length, (i) => i)),
          suggestionPickerProvider.overrideWithValue(() => const [0, 1, 2]),
        ],
        child: Builder(builder: (context) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
              localizationsDelegates: testLocalizationsDelegates,
              home: const HomeScreen());
        }),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('trip-less returning user (chats only) gets the rail',
      (WidgetTester tester) async {
    await pumpHome(tester, chats: [_chat('c1', 'Greek islands')]);

    expect(find.byType(HomeInspirationRail), findsOneWidget);
    expect(find.text('Somewhere new'), findsOneWidget);
    expect(find.byType(DestinationSuggestionCard), findsWidgets);
    // The rail reads the WHOLE-POOL picker, not the 3-chip sample — which
    // provider a surface reads is its stated count contract.
    final draws = tester.widget<RandomSuggestions>(find.descendant(
        of: find.byType(HomeInspirationRail),
        matching: find.byType(RandomSuggestions)));
    expect(draws.picker, same(suggestionOrderProvider));
  });

  testWidgets('new account gets the rail below the photo hero',
      (WidgetTester tester) async {
    await pumpHome(tester);

    expect(find.byType(HomeInspirationRail), findsOneWidget);
  });

  testWidgets('a live trip hides the rail', (WidgetTester tester) async {
    await pumpHome(tester, liveTrip: _liveTrip());

    expect(find.byType(HomeInspirationRail), findsNothing);
  });

  testWidgets('a continue trip hides the rail', (WidgetTester tester) async {
    // The recorded-trip snapshot alone reaches rung 2 — a continue card
    // exists, so inspiration must yield.
    await pumpHome(tester, prefs: {
      'recent_trip.user-1': '{"id":"t9","title":"Lisbon Trip"}',
    });

    expect(find.text('Lisbon Trip'), findsOneWidget);
    expect(find.byType(HomeInspirationRail), findsNothing);
  });

  testWidgets('card tap sends the prompt and switches to the Plan tab',
      (WidgetTester tester) async {
    await pumpHome(tester, chats: [_chat('c1', 'Greek islands')]);

    // Pool order is pinned natural, so the first card is the Paris prompt.
    await tester.ensureVisible(find.byType(DestinationSuggestionCard).first);
    await tester.pump();
    final firstCard = tester
        .widget<DestinationSuggestionCard>(
            find.byType(DestinationSuggestionCard).first);
    await tester.tap(find.byType(DestinationSuggestionCard).first,
        warnIfMissed: false);
    await tester.pump();

    expect(container.read(navIndexProvider), AppTab.plan.index);
    expect(plan.sent, hasLength(1));
    expect(plan.sent.single.$1, firstCard.prompt);
  });
}
