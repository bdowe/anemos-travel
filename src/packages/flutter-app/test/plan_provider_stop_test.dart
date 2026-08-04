import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// stopStreaming(): commits whatever streamed so far as a normal assistant
/// message, fires the transport abort trigger, and supersedes the turn so any
/// tail from the dying stream (late events, teardown) touches nothing.

/// Plays [script] in order — [PlanEvent]s yield, [Completer]s park the stream
/// — and records the abort trigger each turn hands to the transport.
class _StagedPlanService extends PlanService {
  List<Object> script;
  bool aborted = false;

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
    abortTrigger?.whenComplete(() => aborted = true);
    for (final step in script) {
      if (step is Completer<void>) {
        await step.future;
      } else {
        yield step as PlanEvent;
      }
    }
  }
}

void main() {
  test('stop mid-stream commits the partial, aborts, and ignores the tail',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Half an ans'}),
      gate,
      const PlanEvent(type: 'text_delta', data: {'text': 'wer, never seen'}),
      const PlanEvent(type: 'suggest_replies', data: {
        'replies': ['Ghost chip']
      }),
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    final send = notifier.sendMessage('plan athens');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(notifier.state.isStreaming, isTrue);

    notifier.stopStreaming();

    // The un-flushed buffer (not state.streamingText) is what commits — the
    // 48ms coalescing tail must not be lost.
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.streamingText, isNull);
    expect(notifier.state.error, isNull);
    expect(notifier.state.messages.last.role, MessageRole.assistant);
    expect(notifier.state.messages.last.content, 'Half an ans');
    await Future<void>.delayed(Duration.zero);
    expect(service.aborted, isTrue);

    // Release the parked stream: the superseded turn must change nothing.
    gate.complete();
    await send;
    expect(notifier.state.messages.length, 2);
    expect(notifier.state.messages.last.content, 'Half an ans');
    expect(notifier.state.suggestedReplies, isEmpty);
    expect(notifier.state.isStreaming, isFalse);

    // A late flush timer must not resurrect a ghost streaming bubble.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(notifier.state.streamingText, isNull);
  });

  test('stop before any text commits nothing (typing-indicator phase)',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([gate]);
    final notifier = PlanNotifier(service, ApiClient());

    unawaited(notifier.sendMessage('plan athens'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(notifier.state.isStreaming, isTrue);

    notifier.stopStreaming();

    expect(notifier.state.isStreaming, isFalse);
    // Only the user message — no empty assistant bubble.
    expect(notifier.state.messages.map((m) => m.role).toList(),
        [MessageRole.user]);
    await Future<void>.delayed(Duration.zero);
    expect(service.aborted, isTrue);
  });

  test('stop while idle is a no-op (covers double-tap)', () async {
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Done.'}),
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    // Never started: nothing happens.
    notifier.stopStreaming();
    expect(notifier.state.messages, isEmpty);

    await notifier.sendMessage('hi');
    final committed = notifier.state.messages.length;

    // Turn already ended naturally: the second "tap" changes nothing.
    notifier.stopStreaming();
    expect(notifier.state.messages.length, committed);
    expect(notifier.state.isStreaming, isFalse);
  });

  test('stop keeps the queue; the next explicit send drains it FIFO',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'First reply cut'}),
      gate,
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    unawaited(notifier.sendMessage('one'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await notifier.sendMessage('two'); // queued behind the live turn

    notifier.stopStreaming();

    // Stopping is not "success": no auto-drain of a turn the user just killed.
    expect(notifier.state.queuedMessages.map((m) => m.text).toList(), ['two']);
    expect(notifier.state.isStreaming, isFalse);

    // A fresh explicit send drains the backlog FIFO ahead of itself.
    service.script = [
      const PlanEvent(type: 'text_delta', data: {'text': 'ok'}),
    ];
    await notifier.sendMessage('three');
    expect(notifier.state.queuedMessages, isEmpty);
    expect(
      notifier.state.messages
          .where((m) => m.role == MessageRole.user)
          .map((m) => m.content)
          .toList(),
      ['one', 'two', 'three'],
    );
    expect(notifier.state.isStreaming, isFalse);
  });

  test('stop then immediate send starts a clean fresh turn', () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Stale half'}),
      gate,
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    unawaited(notifier.sendMessage('plan athens'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    notifier.stopStreaming();

    service.script = [
      const PlanEvent(type: 'text_delta', data: {'text': 'Fresh answer.'}),
    ];
    await notifier.sendMessage('actually, kyoto');

    expect(notifier.state.messages.last.content, 'Fresh answer.');
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.error, isNull);
  });
}
