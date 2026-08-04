import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// Replays a scripted event list per call and records every request's history
/// and summary — the seam for asserting the compacted wire projection.
class _CompactionPlanService extends PlanService {
  /// Script consumed one list per call; the last list repeats when exhausted.
  final List<List<PlanEvent>> scripts;
  final List<List<Map<String, dynamic>>> histories = [];
  final List<String?> summaries = [];

  /// Consumed by the next call: the stream parks on it after its first event.
  Completer<void>? gate;

  _CompactionPlanService(this.scripts) : super('http://unused');

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
    summaries.add(summary);
    final events = scripts[call < scripts.length ? call : scripts.length - 1];
    var first = true;
    for (final e in events) {
      yield e;
      if (first) {
        first = false;
        final parked = gate;
        gate = null;
        if (parked != null) await parked.future;
      }
    }
  }
}

PlanEvent _compacted(String summary, int through) => PlanEvent(
    type: 'compacted', data: {'summary': summary, 'through_index': through});

const _compacting = PlanEvent(type: 'compacting', data: {});

PlanEvent _delta(String text) =>
    PlanEvent(type: 'text_delta', data: {'text': text});

void main() {
  test('compacted event stores the summary and advances the wire boundary',
      () async {
    final service = _CompactionPlanService([
      [_delta('a1')],
      [_delta('a2')],
      [
        _compacting,
        _compacted('- travelers: 3', 4), // folds all 4 pre-send messages
        _delta('a3'),
      ],
      [_delta('a4')],
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    await notifier.sendMessage('u1');
    await notifier.sendMessage('u2');
    expect(service.summaries, [null, null]);

    await notifier.sendMessage('u3');
    expect(notifier.state.compactedSummary, '- travelers: 3');
    expect(notifier.state.compactedCount, 4);
    expect(notifier.state.isCompacting, isFalse);
    // Display transcript is untouched: 3 user + 3 assistant messages.
    expect(notifier.state.messages, hasLength(6));

    // Next send projects: summary carried, covered prefix excluded.
    await notifier.sendMessage('u4');
    expect(service.summaries.last, '- travelers: 3');
    expect(
      service.histories.last.map((m) => m['content']).toList(),
      ['u3', 'a3', 'u4'],
    );
  });

  test('compacting toggles the chip on and the next event clears it',
      () async {
    final service = _CompactionPlanService([
      [_compacting, _delta('reply')],
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    final gate = Completer<void>();
    service.gate = gate;
    final send = notifier.sendMessage('hello');
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.isCompacting, isTrue);

    gate.complete();
    await send;
    expect(notifier.state.isCompacting, isFalse);
    // No compacted event followed (failed compaction): state untouched.
    expect(notifier.state.compactedSummary, isNull);
    expect(notifier.state.compactedCount, 0);
  });

  test('error after compacted keeps the advanced state; retry resends the '
      'compacted projection', () async {
    final service = _CompactionPlanService([
      [_delta('a1')],
      [
        _compacting,
        _compacted('- summary', 2),
        const PlanEvent(type: 'error', data: {'message': 'boom'}),
      ],
      [_delta('recovered')],
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    await notifier.sendMessage('u1');
    await notifier.sendMessage('u2');
    expect(notifier.state.error, 'boom');
    expect(notifier.state.compactedCount, 2);

    await notifier.retryLastSend();
    expect(notifier.state.error, isNull);
    expect(service.summaries.last, '- summary');
    // The retried turn resends only the uncovered tail: just 'u2'.
    expect(
      service.histories.last.map((m) => m['content']).toList(),
      ['u2'],
    );
    expect(notifier.state.messages.last.content, 'recovered');
  });

  test('queued message drained after a compaction uses the new boundary',
      () async {
    final service = _CompactionPlanService([
      [
        _compacting,
        _compacted('- state', 1), // folds the sole pre-send user message
        _delta('a1'),
      ],
      [_delta('a2')],
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    final gate = Completer<void>();
    service.gate = gate;
    final first = notifier.sendMessage('u1');
    await notifier.sendMessage('u2'); // queued mid-stream
    gate.complete();
    await first;

    expect(service.histories, hasLength(2));
    expect(service.summaries.last, '- state');
    // u1 is covered by the summary; the drained send carries a1 + u2 only.
    expect(
      service.histories.last.map((m) => m['content']).toList(),
      ['a1', 'u2'],
    );
    expect(notifier.state.messages.map((m) => m.content).toList(),
        ['u1', 'a1', 'u2', 'a2']);
  });

  test('reset clears compaction state', () async {
    final service = _CompactionPlanService([
      [_compacting, _compacted('- s', 1), _delta('a')],
    ]);
    final notifier = PlanNotifier(service, ApiClient());
    await notifier.sendMessage('u1');
    expect(notifier.state.compactedCount, 1);

    notifier.reset();
    expect(notifier.state.compactedSummary, isNull);
    expect(notifier.state.compactedCount, 0);
    expect(notifier.state.isCompacting, isFalse);
  });
}
