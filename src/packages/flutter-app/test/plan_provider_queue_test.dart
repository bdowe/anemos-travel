import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// Yields one text_delta per call ('reply N'), optionally parking on [gate]
/// after the delta so tests can enqueue mid-stream, and optionally ending the
/// turn with an SSE error. Records the history payload of every call.
class _GatedPlanService extends PlanService {
  final List<List<Map<String, dynamic>>> histories = [];

  /// Consumed by the next call: the stream parks on it after its first delta.
  Completer<void>? gate;

  /// Consumed by the next call: end the turn with an error event.
  bool failNext = false;

  _GatedPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    final call = histories.length;
    histories.add(List.of(messages));
    yield PlanEvent(type: 'text_delta', data: {'text': 'reply $call'});
    final parked = gate;
    gate = null;
    if (parked != null) await parked.future;
    if (failNext) {
      failNext = false;
      yield const PlanEvent(type: 'error', data: {'message': 'boom'});
    }
  }
}

/// Starts a gated turn for 'a' and queues 'b' behind it, then fails the turn:
/// the shared setup for the error-path tests.
Future<void> _failedTurnWithBacklog(
    _GatedPlanService service, PlanNotifier notifier) async {
  final gate = Completer<void>();
  service.gate = gate;
  service.failNext = true;
  final first = notifier.sendMessage('a');
  await notifier.sendMessage('b');
  gate.complete();
  await first;
}

void main() {
  test('messages sent mid-stream queue up and drain FIFO on completion',
      () async {
    final service = _GatedPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    final gate = Completer<void>();
    service.gate = gate;
    final first = notifier.sendMessage('a');
    expect(notifier.state.isStreaming, isTrue);

    await notifier.sendMessage('b');
    await notifier.sendMessage('c');
    expect(
        notifier.state.queuedMessages.map((m) => m.text).toList(), ['b', 'c']);
    // Mid-stream sends are queued, not committed to the transcript.
    expect(notifier.state.messages.map((m) => m.content).toList(), ['a']);

    gate.complete();
    await first;

    expect(notifier.state.queuedMessages, isEmpty);
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.messages.map((m) => m.role).toList(), [
      MessageRole.user,
      MessageRole.assistant,
      MessageRole.user,
      MessageRole.assistant,
      MessageRole.user,
      MessageRole.assistant,
    ]);
    expect(
      notifier.state.messages
          .where((m) => m.role == MessageRole.user)
          .map((m) => m.content)
          .toList(),
      ['a', 'b', 'c'],
    );
    // Each drained turn carried the full transcript so far.
    expect(service.histories.length, 3);
    expect(service.histories[1].map((m) => m['content']).toList(),
        ['a', 'reply 0', 'b']);
    expect(service.histories[2].map((m) => m['content']).toList(),
        ['a', 'reply 0', 'b', 'reply 1', 'c']);
  });

  test('removeQueued drops a pending message before it sends', () async {
    final service = _GatedPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    final gate = Completer<void>();
    service.gate = gate;
    final first = notifier.sendMessage('a');
    await notifier.sendMessage('b');
    await notifier.sendMessage('c');

    notifier.removeQueued(notifier.state.queuedMessages.first.id);
    expect(notifier.state.queuedMessages.map((m) => m.text).toList(), ['c']);

    gate.complete();
    await first;

    expect(
      notifier.state.messages
          .where((m) => m.role == MessageRole.user)
          .map((m) => m.content)
          .toList(),
      ['a', 'c'],
    );
    expect(service.histories.length, 2);
  });

  test('an error keeps the queue; retry runs the failed turn first, then drains',
      () async {
    final service = _GatedPlanService();
    final notifier = PlanNotifier(service, ApiClient());
    await _failedTurnWithBacklog(service, notifier);

    expect(notifier.state.error, 'boom');
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.queuedMessages.map((m) => m.text).toList(), ['b']);
    // No drain on error.
    expect(service.histories.length, 1);

    await notifier.retryLastSend();

    expect(notifier.state.error, isNull);
    expect(notifier.state.queuedMessages, isEmpty);
    expect(
      notifier.state.messages
          .where((m) => m.role == MessageRole.user)
          .map((m) => m.content)
          .toList(),
      ['a', 'b'],
    );
    // The retried turn ran before the queued one, with no duplicate user turn.
    expect(service.histories.length, 3);
    expect(
        service.histories[1].where((m) => m['role'] == 'user').length, 1);
    expect(service.histories[1].first['content'], 'a');
  });

  test('sending while idle with a backlog goes to the back, head sends first',
      () async {
    final service = _GatedPlanService();
    final notifier = PlanNotifier(service, ApiClient());
    await _failedTurnWithBacklog(service, notifier);

    // Idle, error shown, 'b' still queued. A fresh send must not jump it.
    await notifier.sendMessage('c');

    expect(notifier.state.error, isNull);
    expect(notifier.state.queuedMessages, isEmpty);
    expect(
      notifier.state.messages
          .where((m) => m.role == MessageRole.user)
          .map((m) => m.content)
          .toList(),
      ['a', 'b', 'c'],
    );
  });

  test('reset clears the queue', () async {
    final service = _GatedPlanService();
    final notifier = PlanNotifier(service, ApiClient());
    await _failedTurnWithBacklog(service, notifier);
    expect(notifier.state.queuedMessages, isNotEmpty);

    notifier.reset();

    expect(notifier.state.queuedMessages, isEmpty);
    expect(notifier.state.messages, isEmpty);
  });

  test('dispose mid-stream with queued messages neither throws nor drains',
      () async {
    final service = _GatedPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    final gate = Completer<void>();
    service.gate = gate;
    final first = notifier.sendMessage('a');
    await notifier.sendMessage('b');

    notifier.dispose();
    gate.complete();
    await first;

    expect(service.histories.length, 1);
  });
}
