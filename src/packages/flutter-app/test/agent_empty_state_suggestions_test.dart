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
import 'package:travel_route_planner/widgets/destination_suggestion_card.dart';
import 'package:travel_route_planner/widgets/fading_edge_scroll.dart';
import 'package:travel_route_planner/widgets/near_me_chip.dart';

import 'support/l10n_test_app.dart';

/// The Plan tab's opening state: a heading and one line of what the agent will
/// do, floating in the space above; then the shuffled destination pool as a
/// horizontal rail, and the two non-typing ways in as chips, both sitting
/// directly against the composer.
///
/// The composition IS the feature here — the screen this replaced put the same
/// pieces in the vertical centre with a couple of hundred pixels of nothing
/// between them and the input — so the order and the gap are asserted, not
/// just the presence of the parts.
///
/// The pool order is drawn once per mount (a locale switch relabels WITHOUT
/// reshuffling; a chat reset re-rolls), and tapping a card sends exactly the
/// visible label.

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

  setUp(() {
    plan = _RecordingPlanNotifier();
    pickerCalls = 0;
    // Beyond the legacy trio (proves pool wiring), and few enough that the
    // whole order fits on one rail at the default 800px test surface.
    nextPicks = const [3, 4, 5];
  });

  testWidgets('the rail shows more than one destination at once',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    // The carousel this replaced showed exactly one card and hid the rest
    // behind a five-second dwell; the rail's whole argument is that a second
    // idea is visible without waiting for it.
    expect(find.text('Island hopping in Greece'), findsOneWidget);
    expect(find.text('3 days in Lisbon'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('heading, rail, chips, composer — in that order, no void',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    final heading = tester.getRect(find.text('Tell me about your trip'));
    final rail =
        tester.getRect(find.byType(DestinationSuggestionCard).first);
    final chips = tester.getRect(find.byType(NearMeChip));
    final composer = tester.getRect(find.byType(TextField));

    expect(heading.bottom, lessThan(rail.top));
    expect(rail.bottom, lessThanOrEqualTo(chips.top));
    expect(chips.bottom, lessThan(composer.top));

    // The point of the redesign: the starters hang off the composer. The old
    // layout centred everything and left ~200px of nothing here, so a
    // generous ceiling still fails the thing this replaced.
    expect(composer.top - chips.bottom, lessThan(64),
        reason: 'the starters must sit against the composer, not the centre');

    // ...and the reading block is NOT crammed against the app bar either: it
    // keeps the field above it that makes the block read as composed.
    expect(heading.top, greaterThan(tester.getRect(find.byType(AppBar)).bottom),
        reason: 'the heading sits below the app bar, in its own field');
  });

  testWidgets('the rail dissolves at its edges, like the home rails',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    expect(find.byType(FadingEdgeScroll), findsOneWidget);

    // The fade is derived from the controller FadingEdgeScroll hands out, so
    // a ListView that builds its own (or none) leaves the mask frozen at
    // "no edges" and the rail silently reverts to a hard cut. Pinning the
    // wiring, not the pixels: the gradient itself is covered by
    // fading_edge_scroll_test.
    final rail = tester.widget<ListView>(find.descendant(
      of: find.byType(FadingEdgeScroll),
      matching: find.byType(ListView),
    ));
    expect(rail.controller, isNotNull,
        reason: 'the rail must take the controller it is handed');
  });

  testWidgets('near-me and import are the two starter chips',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    expect(find.byType(NearMeChip), findsOneWidget);
    // Import navigates rather than sending, but beside the near-me chip it is
    // the same kind of offer, so it wears the same clothes.
    expect(
      find.widgetWithText(ActionChip, 'Import from AI chat'),
      findsOneWidget,
    );
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('every card carries its own destination photo and credit',
      (WidgetTester tester) async {
    await pumpAgent(tester, overrides());

    // Order [3, 4, 5] is Greece, Lisbon, Barcelona — each card must carry ITS
    // photo, which a parallel-list wiring bug would silently scramble.
    final cards = tester
        .widgetList<DestinationSuggestionCard>(
            find.byType(DestinationSuggestionCard))
        .toList();
    expect(cards.first.asset, kDestinationPhotos['greece']!.asset);
    expect(cards[1].asset, kDestinationPhotos['lisbon']!.asset);
    // Attribution is a license obligation, so it is rendered, not optional.
    expect(cards.first.credit, isNotEmpty);
    expect(find.text(cards.first.credit), findsOneWidget);
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
    expect(find.byType(DestinationSuggestionCard), findsNothing);

    // ...and the app-bar reset brings it back with a fresh draw.
    nextPicks = const [6, 7, 8];
    plan.reset();
    await tester.pump();
    expect(pickerCalls, 2);
    expect(find.text('Street food in Bangkok'), findsOneWidget);
  });

  testWidgets('a short viewport scrolls the whole block instead of overflowing',
      (WidgetTester tester) async {
    // A 320x568 phone, less an app bar and a composer, leaves the reading
    // block no field to float in — below that floor everything joins one
    // scroll rather than being squeezed.
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpAgent(tester, overrides());

    expect(tester.takeException(), isNull);
    expect(find.text('Tell me about your trip'), findsOneWidget);
    expect(find.byType(DestinationSuggestionCard), findsWidgets);
  });
}
