import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// The typing indicator appears the instant a turn starts (before any SSE
/// event) and yields to whichever feedback owns the moment: streamed text,
/// tool chips, or the compacting chip — returning in the silent gap after a
/// tool_result, and below already-streamed text whenever the server signals
/// `thinking` (specs/chat-working-indicator).

const _indicator = Key('typing-indicator');

/// Plays [script] in order: [PlanEvent]s are yielded, [Completer]s are
/// awaited — so a test can park the stream at any point (including before the
/// first event) and observe mid-stream UI.
class _StagedPlanService extends PlanService {
  final List<Object> script;

  _StagedPlanService(this.script) : super('http://unused');

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

Future<void> _pumpPanel(WidgetTester tester, _StagedPlanService service) async {
  final notifier = PlanNotifier(service, ApiClient());
  final provider =
      StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
}

Future<void> _send(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'hi');
  await tester.tap(find.byIcon(Icons.send));
  await tester.pump();
}

void main() {
  testWidgets('visible from the instant of send, gone at the first token',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final afterFirstToken = Completer<void>();
    final service = _StagedPlanService([
      gate,
      const PlanEvent(type: 'text_delta', data: {'text': 'Hello there'}),
      afterFirstToken,
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    // No SSE event has arrived (the stream is parked) — the indicator is
    // already up, keyed off the synchronous isStreaming flip.
    expect(find.byKey(_indicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(_indicator), findsOneWidget);

    gate.complete();
    // The stream parks again AFTER the first token, so the 48ms flush fires
    // while isStreaming is still true: the indicator must yield to the live
    // streaming bubble mid-stream, not merely at turn end.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(_indicator), findsNothing);
    expect(find.text('Hello there'), findsOneWidget);

    afterFirstToken.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(_indicator), findsNothing);
    expect(find.text('Hello there'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('yields to tool chips, returns in the post-tool gap',
      (WidgetTester tester) async {
    final afterToolCall = Completer<void>();
    final afterToolResult = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'tool_call', data: {'name': 'search_flights'}),
      afterToolCall,
      const PlanEvent(type: 'tool_result', data: {'name': 'search_flights'}),
      afterToolResult,
      const PlanEvent(type: 'text_delta', data: {'text': 'Found options.'}),
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump(const Duration(milliseconds: 20));
    // The spinner chip owns the feedback while a tool runs.
    expect(find.text('Searching flights...'), findsOneWidget);
    expect(find.byKey(_indicator), findsNothing);

    afterToolCall.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // Tool done, no text yet — the silent gap belongs to the indicator.
    expect(find.text('Searching flights...'), findsNothing);
    expect(find.byKey(_indicator), findsOneWidget);

    afterToolResult.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(_indicator), findsNothing);
    expect(find.text('Found options.'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('returns below streamed text on thinking, gone at the next token',
      (WidgetTester tester) async {
    final afterText = Completer<void>();
    final afterThinking = Completer<void>();
    final afterMoreText = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Step one done.'}),
      afterText,
      const PlanEvent(type: 'thinking', data: {}),
      afterThinking,
      const PlanEvent(type: 'text_delta', data: {'text': ' And step two.'}),
      afterMoreText,
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Text streamed and the stream is parked with no thinking signal: this
    // was the old dead window — dots stay hidden until the server says so.
    expect(find.text('Step one done.'), findsOneWidget);
    expect(find.byKey(_indicator), findsNothing);

    afterText.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // The server is between steps: dots return BELOW the streamed text.
    expect(find.text('Step one done.'), findsOneWidget);
    expect(find.byKey(_indicator), findsOneWidget);

    afterThinking.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // The next token ends the wait — dots never overlap live streaming.
    expect(find.byKey(_indicator), findsNothing);
    expect(find.text('Step one done. And step two.'), findsOneWidget);
    afterMoreText.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('thinking yields to a tool chip', (WidgetTester tester) async {
    final afterThinking = Completer<void>();
    final afterToolCall = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Looking around.'}),
      const PlanEvent(type: 'thinking', data: {}),
      afterThinking,
      const PlanEvent(type: 'tool_call', data: {'name': 'search_flights'}),
      afterToolCall,
      const PlanEvent(type: 'tool_result', data: {'name': 'search_flights'}),
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(_indicator), findsOneWidget);

    afterThinking.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // The chip owns the feedback; exactly one indicator at a time.
    expect(find.text('Searching flights...'), findsOneWidget);
    expect(find.byKey(_indicator), findsNothing);
    afterToolCall.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('hidden while the server summarizes (compacting chip owns it)',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'compacting', data: {}),
      gate,
      const PlanEvent(type: 'text_delta', data: {'text': 'Done thinking.'}),
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Summarizing earlier conversation…'), findsOneWidget);
    expect(find.byKey(_indicator), findsNothing);

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(_indicator), findsNothing);
    expect(find.text('Done thinking.'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
