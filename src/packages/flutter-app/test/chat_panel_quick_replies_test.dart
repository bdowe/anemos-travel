import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Quick replies (specs/chat-quick-replies): the SSE `suggest_replies` event
/// populates PlanState.suggestedReplies (whole-list replacement,
/// last-write-wins), tap sends the chip text verbatim, and the chips row
/// hides while streaming or while a queued follow-up supersedes the question.

/// Captures the history payload and replays a canned event list; optionally
/// throws after the events (a mid-stream transport failure).
class _ScriptedPlanService extends PlanService {
  final List<PlanEvent> events;
  final Object? throwAfterEvents;
  List<Map<String, dynamic>>? lastHistory;

  _ScriptedPlanService(this.events, {this.throwAfterEvents})
      : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    lastHistory = messages;
    for (final e in events) {
      yield e;
    }
    if (throwAfterEvents != null) throw throwAfterEvents!;
  }
}

/// Plays [script] in order: [PlanEvent]s are yielded, [Completer]s awaited —
/// so a test can park the stream mid-turn (e.g. to reset() underneath it).
class _ParkablePlanService extends PlanService {
  final List<Object> script;

  _ParkablePlanService(this.script) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final step in script) {
      if (step is Completer<void>) {
        await step.future;
      } else {
        yield step as PlanEvent;
      }
    }
  }
}

class _SeededPlanNotifier extends PlanNotifier {
  _SeededPlanNotifier(PlanState seeded, PlanService service, {String? tripId})
      : super(service, ApiClient(), tripId: tripId) {
    state = seeded;
  }
}

PlanEvent _replies(List<String> replies) =>
    PlanEvent(type: 'suggest_replies', data: {'replies': replies});

PlanState _answeredState({
  List<String> replies = const ['Mid-range budget', 'Luxury all the way'],
  bool isStreaming = false,
  List<QueuedMessage> queued = const [],
}) =>
    PlanState(
      messages: [
        PlanMessage(role: MessageRole.user, content: 'plan me something warm'),
        PlanMessage(
            role: MessageRole.assistant, content: 'What budget suits you?'),
      ],
      suggestedReplies: replies,
      isStreaming: isStreaming,
      queuedMessages: queued,
    );

Future<_ScriptedPlanService> _pumpSeeded(
    WidgetTester tester, PlanState seeded,
    {String? tripId}) async {
  final service = _ScriptedPlanService([]);
  final provider = StateNotifierProvider<PlanNotifier, PlanState>(
      (ref) => _SeededPlanNotifier(seeded, service, tripId: tripId));
  await tester.pumpWidget(
    ProviderScope(
      child: localizedTestApp(
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
  await tester.pump();
  return service;
}

void main() {
  group('provider', () {
    test('suggest_replies populates the list; later events overwrite',
        () async {
      final service = _ScriptedPlanService([
        _replies(const ['Yes', 'No']),
        _replies(const ['Beach', 'Mountains']),
      ]);
      final notifier = PlanNotifier(service, ApiClient());
      final seen = <List<String>>[];
      notifier.addListener((s) {
        if (seen.isEmpty || !identical(seen.last, s.suggestedReplies)) {
          seen.add(s.suggestedReplies);
        }
      });

      await notifier.sendMessage('hi');
      // Last write wins, and each event replaced the list (new identity).
      expect(notifier.state.suggestedReplies, ['Beach', 'Mountains']);
      expect(
          seen.where((l) => l.isNotEmpty).map((l) => l.first).toList(),
          containsAllInOrder(['Yes', 'Beach']));
    });

    test('the next send clears the previous turn\'s replies', () async {
      final service = _ScriptedPlanService([
        _replies(const ['Yes', 'No'])
      ]);
      final notifier = PlanNotifier(service, ApiClient());
      await notifier.sendMessage('hi');
      expect(notifier.state.suggestedReplies, isNotEmpty);

      service.events.clear();
      await notifier.sendMessage('actually, surprise me');
      expect(notifier.state.suggestedReplies, isEmpty);
    });

    test('a terminal error clears the replies', () async {
      final notifier = PlanNotifier(
          _ScriptedPlanService([
            _replies(const ['Yes', 'No']),
            const PlanEvent(type: 'error', data: {'message': 'stream died'}),
          ]),
          ApiClient());
      await notifier.sendMessage('hi');
      expect(notifier.state.error, 'stream died');
      expect(notifier.state.suggestedReplies, isEmpty);
    });

    test('a transport error (stream throws) clears the replies', () async {
      final notifier = PlanNotifier(
          _ScriptedPlanService([
            _replies(const ['Yes', 'No']),
          ], throwAfterEvents: Exception('connection dropped')),
          ApiClient());
      await notifier.sendMessage('hi');
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.suggestedReplies, isEmpty);
    });

    test('an itinerary turn drops the chips — either event order', () async {
      const done =
          PlanEvent(type: 'done', data: {'locations': [], 'summary': 's'});
      for (final events in [
        [_replies(const ['Yes', 'No']), done],
        [done, _replies(const ['Yes', 'No'])],
      ]) {
        final notifier =
            PlanNotifier(_ScriptedPlanService(events), ApiClient());
        await notifier.sendMessage('hi');
        expect(notifier.state.suggestedReplies, isEmpty,
            reason: 'the itinerary banner owns the turn');
      }
    });

    test('a refine (trip_updated) turn drops the chips', () async {
      final notifier = PlanNotifier(
          _ScriptedPlanService([
            const PlanEvent(type: 'trip_updated', data: {}),
            _replies(const ['Yes', 'No']),
          ]),
          ApiClient(),
          tripId: 't1');
      await notifier.sendMessage('hi');
      expect(notifier.state.suggestedReplies, isEmpty);
    });

    test('reset() mid-stream discards the stale turn — no chip leak',
        () async {
      final gate = Completer<void>();
      final notifier = PlanNotifier(
          _ParkablePlanService([gate, _replies(const ['Yes', 'No'])]),
          ApiClient());
      final send = notifier.sendMessage('hi');
      await Future<void>.delayed(Duration.zero); // let the stream start
      notifier.reset();
      gate.complete();
      await send; // the superseded loop self-terminates

      expect(notifier.state.messages, isEmpty);
      expect(notifier.state.suggestedReplies, isEmpty);
      expect(notifier.state.isStreaming, isFalse);
    });

    test('suggest_replies never appears as an active tool chip', () async {
      final notifier = PlanNotifier(
          _ScriptedPlanService([
            const PlanEvent(type: 'tool_call', data: {'name': 'suggest_replies'}),
            _replies(const ['Yes', 'No']),
            const PlanEvent(
                type: 'tool_result', data: {'name': 'suggest_replies'}),
          ]),
          ApiClient());
      var sawInActiveTools = false;
      notifier.addListener((s) {
        if (s.activeTools.contains('suggest_replies')) sawInActiveTools = true;
      });
      await notifier.sendMessage('hi');
      expect(sawInActiveTools, isFalse);
      expect(notifier.state.suggestedReplies, ['Yes', 'No']);
    });
  });

  group('widget', () {
    testWidgets('settled turn shows chips; tap sends verbatim and clears',
        (WidgetTester tester) async {
      final service = await _pumpSeeded(tester, _answeredState());

      expect(find.text('Mid-range budget'), findsOneWidget);
      expect(find.text('Luxury all the way'), findsOneWidget);

      await tester.tap(find.text('Mid-range budget'));
      await tester.pump();

      // The tapped text went out verbatim as the next user message…
      final lastUser =
          service.lastHistory!.lastWhere((m) => m['role'] == 'user');
      expect(lastUser['content'], 'Mid-range budget');
      // …and the chips row is gone (cleared by the send).
      expect(find.byType(ActionChip), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('hidden while a turn is streaming',
        (WidgetTester tester) async {
      await _pumpSeeded(
          tester, _answeredState(isStreaming: true));
      expect(find.text('Mid-range budget'), findsNothing);
    });

    testWidgets('hidden while a queued follow-up supersedes the question',
        (WidgetTester tester) async {
      await _pumpSeeded(
          tester,
          _answeredState(
              queued: const [QueuedMessage(id: 1, text: 'add delphi')]));
      expect(find.text('Mid-range budget'), findsNothing);
    });

    testWidgets('works under a trip-refine-shaped host (tripId bound)',
        (WidgetTester tester) async {
      final service =
          await _pumpSeeded(tester, _answeredState(), tripId: 'trip-1');

      expect(find.text('Mid-range budget'), findsOneWidget);
      await tester.tap(find.text('Luxury all the way'));
      await tester.pump();
      final lastUser =
          service.lastHistory!.lastWhere((m) => m['role'] == 'user');
      expect(lastUser['content'], 'Luxury all the way');
      await tester.pumpAndSettle();
    });
  });
}
