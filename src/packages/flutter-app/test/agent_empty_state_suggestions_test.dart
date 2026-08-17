import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/notifications_provider.dart';
import 'package:travel_route_planner/providers/destination_photos.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/screens/agent_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/destination_carousel.dart';
import 'package:travel_route_planner/widgets/destination_suggestion_card.dart';
import 'package:travel_route_planner/widgets/empty_state.dart';
import 'package:travel_route_planner/widgets/near_me_chip.dart';

import 'support/l10n_test_app.dart';

/// The agent screen's empty state shuffles the whole destination pool and
/// cycles it as a self-advancing carousel: one card on screen at a time in the
/// content slot, the near-me chip and the import-from-AI-chat button stay in
/// actions (both are actions rather than destinations, and the import one is
/// a button because it navigates instead of sending), the order is drawn once
/// per mount (a locale switch relabels WITHOUT reshuffling; a chat reset
/// re-rolls), and tapping a card sends exactly the visible label.
///
/// Auto-advance is a `Timer`, and it is suppressed on a hidden tab, under
/// reduced motion / a screen reader, and once the traveler has dragged the
/// cards themselves — each pinned below.

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
        suggestionOrderProvider.overrideWithValue(() {
          pickerCalls++;
          return nextPicks;
        }),
      ];

  Future<void> pumpAgent(WidgetTester tester, List<Override> overrides,
      {Locale? locale, Widget Function(Widget child)? wrap}) async {
    const screen = AgentScreen();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: localizedTestApp(
          home: wrap == null ? screen : wrap(screen),
          locale: locale,
        ),
      ),
    );
    await tester.pump();
  }

  /// One dwell plus the slide. The carousel's own timings are private; a test
  /// that waited exactly them would pass on a stuck carousel too.
  Future<void> waitOneDwell(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  setUp(() {
    plan = _RecordingPlanNotifier();
    pickerCalls = 0;
    // Beyond the legacy trio (proves pool wiring), and short enough that
    // cycling all the way round is three advances rather than twelve.
    nextPicks = const [3, 4, 5];
  });

  testWidgets('one card at a time; near-me and import stay actions',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    final emptyState = tester.widget<EmptyState>(find.byType(EmptyState));
    expect(emptyState.actions.first, isA<NearMeChip>());
    expect(emptyState.actions.last, isA<OutlinedButton>());
    expect(emptyState.actions, hasLength(2),
        reason: 'destinations belong in the content slot, not actions');
    // The photos are the visual anchor; a generic glyph over them is weight.
    expect(emptyState.icon, isNull);

    expect(find.byType(DestinationSuggestionCarousel), findsOneWidget);
    expect(find.text('Island hopping in Greece'), findsOneWidget);
    // The rest of the order is a slide away, not stacked underneath.
    expect(find.text('3 days in Lisbon'), findsNothing);
    expect(find.text('2 days in Paris'), findsNothing);
  });

  testWidgets('the carousel advances itself, and wraps',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());
    expect(find.text('Island hopping in Greece'), findsOneWidget);

    await waitOneDwell(tester);
    expect(find.text('3 days in Lisbon'), findsOneWidget);
    expect(find.text('Island hopping in Greece'), findsNothing);

    await waitOneDwell(tester);
    expect(find.text('Tapas in Barcelona'), findsOneWidget);

    // Past the last destination it comes round again — forwards, which is why
    // the pages run without end instead of animating back to index 0. Waited
    // for rather than counted: how many dwells fit in a pumped interval is an
    // implementation detail, that it comes back round is the contract.
    var dwells = 0;
    while (find.text('Island hopping in Greece').evaluate().isEmpty) {
      expect(dwells++, lessThan(nextPicks.length * 2),
          reason: 'the carousel never came back round');
      await waitOneDwell(tester);
    }
  });

  testWidgets('a hidden tab does not keep sliding',
      (WidgetTester tester) async {
    // AppShell keeps every tab mounted and freezes hidden ones with
    // TickerMode — which does NOT stop a Timer on its own.
    await pumpAgent(tester, overrides(),
        wrap: (child) => TickerMode(enabled: false, child: child));

    await waitOneDwell(tester);
    expect(find.text('Island hopping in Greece'), findsOneWidget);
  });

  testWidgets('reduced motion stops the auto-advance',
      (WidgetTester tester) async {
    await pumpAgent(
      tester,
      overrides(),
      wrap: (child) => Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child,
        ),
      ),
    );

    await waitOneDwell(tester);
    expect(find.text('Island hopping in Greece'), findsOneWidget);
  });

  testWidgets('a drag hands the cards over for good',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('3 days in Lisbon'), findsOneWidget);

    // No yanking a card out from under a thumb.
    await waitOneDwell(tester);
    expect(find.text('3 days in Lisbon'), findsOneWidget);
  });

  testWidgets('the visible card shows its own destination photo and credit',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    // Order [3, 4, 5] is Greece, Lisbon, Barcelona — each card must carry ITS
    // photo, which a parallel-list wiring bug would silently scramble.
    var card = tester.widget<DestinationSuggestionCard>(
        find.byType(DestinationSuggestionCard));
    expect(card.asset, kDestinationPhotos['greece']!.asset);
    // Attribution is a license obligation, so it is rendered, not optional.
    expect(card.credit, isNotEmpty);
    expect(find.text(card.credit), findsOneWidget);

    await waitOneDwell(tester);
    card = tester.widget<DestinationSuggestionCard>(
        find.byType(DestinationSuggestionCard));
    expect(card.asset, kDestinationPhotos['lisbon']!.asset);
    expect(find.text(card.credit), findsOneWidget);
  });

  testWidgets('tapping a card sends exactly the visible label',
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
