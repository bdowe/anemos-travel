import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/notifications_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/screens/agent_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/empty_state.dart';
import 'package:travel_route_planner/widgets/near_me_chip.dart';

import 'support/l10n_test_app.dart';

/// The agent screen's empty state draws its suggestion chips from the shared
/// randomized pool: the near-me chip always leads, exactly
/// [kSuggestionCount] pool picks follow (the import-from-AI-chat button
/// closes the row — a button, not a chip, because it navigates instead of
/// sending), a pick is drawn once per mount (a locale switch relabels
/// WITHOUT reshuffling; a chat reset re-rolls), and tapping a chip sends
/// exactly the visible label.

class _RecordingPlanNotifier extends PlanNotifier {
  final List<(String, String?)> sent = [];

  _RecordingPlanNotifier() : super(PlanService('http://unused'), ApiClient());

  /// Test hook: drive the chat between empty and non-empty so the empty
  /// state unmounts/remounts like a real conversation start + reset.
  void seed(PlanState s) => state = s;

  @override
  Future<void> sendMessage(String text,
      {String? displayLabel,
      List<PlanAttachment> attachments = const []}) async {
    sent.add((text, displayLabel));
  }
}

class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier() : super(AuthState(user: null, initialized: true));

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

void main() {
  late _RecordingPlanNotifier plan;
  late int pickerCalls;
  late List<int> nextPicks;

  /// One ProviderScope whose overrides list is reused verbatim across
  /// re-pumps, so elements (and the mounted picks) survive a locale change.
  List<Override> overrides() => [
        planProvider.overrideWith((ref) => plan),
        authProvider.overrideWith((ref) => _FakeAuthNotifier()),
        notificationsUnreadCountProvider.overrideWith((ref) async => 0),
        suggestionPickerProvider.overrideWithValue(() {
          pickerCalls++;
          return nextPicks;
        }),
      ];

  Future<void> pumpAgent(WidgetTester tester, List<Override> overrides,
      {Locale? locale}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: localizedTestApp(home: const AgentScreen(), locale: locale),
      ),
    );
    await tester.pump();
  }

  setUp(() {
    plan = _RecordingPlanNotifier();
    pickerCalls = 0;
    nextPicks = const [3, 4, 5]; // beyond the legacy trio: proves pool wiring
  });

  testWidgets('renders near-me first plus the picked pool prompts',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    final emptyState = tester.widget<EmptyState>(find.byType(EmptyState));
    expect(emptyState.actions.first, isA<NearMeChip>());
    // near-me + pool picks + the trailing import entry point.
    expect(emptyState.actions, hasLength(1 + kSuggestionCount + 1));
    expect(emptyState.actions.last, isA<OutlinedButton>());

    expect(find.text('Island hopping in Greece'), findsOneWidget);
    expect(find.text('3 days in Lisbon'), findsOneWidget);
    expect(find.text('Tapas in Barcelona'), findsOneWidget);
    expect(find.text('2 days in Paris'), findsNothing);
  });

  testWidgets('tapping a chip sends exactly the visible label',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    await tester.tap(find.text('Island hopping in Greece'));
    await tester.pump();

    expect(plan.sent.single.$1, 'Island hopping in Greece');
    expect(plan.sent.single.$2, isNull);
  });

  testWidgets('locale switch relabels the same picks without reshuffling',
      (WidgetTester tester) async {
    nextPicks = const [0, 1, 2];
    final scopeOverrides = overrides();

    await pumpAgent(tester, scopeOverrides, locale: const Locale('en'));
    expect(pickerCalls, 1);
    expect(find.text('2 days in Paris'), findsOneWidget);

    await pumpAgent(tester, scopeOverrides, locale: const Locale('es'));
    expect(pickerCalls, 1, reason: 'a locale change must not re-draw');
    expect(find.text('2 días en París'), findsOneWidget);
  });

  testWidgets('a chat reset re-rolls the picks', (WidgetTester tester) async {
    final scopeOverrides = overrides();
    await pumpAgent(tester, scopeOverrides);
    expect(pickerCalls, 1);

    // Conversation starts: the empty state unmounts...
    plan.seed(PlanState(messages: [
      PlanMessage(role: MessageRole.user, content: 'plan athens'),
    ]));
    await tester.pump();
    expect(find.byType(EmptyState), findsNothing);

    // ...and the app-bar reset brings it back with a fresh draw.
    nextPicks = const [6, 7, 8];
    plan.reset();
    await tester.pump();
    expect(pickerCalls, 2);
    expect(find.text('Street food in Bangkok'), findsOneWidget);
  });
}
