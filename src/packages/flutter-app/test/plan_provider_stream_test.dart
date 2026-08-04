import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// Emits [deltaCount] text_delta events a couple of milliseconds apart —
/// far faster than the notifier's flush interval, like the real SSE stream.
class _FakePlanService extends PlanService {
  final int deltaCount;

  _FakePlanService(this.deltaCount) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (var i = 0; i < deltaCount; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      yield PlanEvent(type: 'text_delta', data: {'text': 'tok$i '});
    }
  }
}

/// Captures the history payload and replays a canned event list, so tests can
/// assert what the server would receive and how events mutate state.
class _ScriptedPlanService extends PlanService {
  final List<PlanEvent> events;
  List<Map<String, dynamic>>? lastHistory;

  _ScriptedPlanService(this.events) : super('http://unused');

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
  }
}

void main() {
  test('text deltas are coalesced into far fewer state emissions', () async {
    const deltas = 60;
    final notifier = PlanNotifier(_FakePlanService(deltas), ApiClient());

    var streamingEmissions = 0;
    String? lastStreaming;
    notifier.addListener((state) {
      if (state.streamingText != lastStreaming) {
        lastStreaming = state.streamingText;
        if (state.streamingText != null) streamingEmissions++;
      }
    });

    await notifier.sendMessage('hi');

    // ~120ms of 2ms-apart deltas against a 48ms flush interval → a handful of
    // emissions, never one per token.
    expect(streamingEmissions, greaterThan(0));
    expect(streamingEmissions, lessThan(deltas ~/ 3));

    // No token lost to coalescing: the committed message is the concatenation.
    final expected = List.generate(deltas, (i) => 'tok$i ').join();
    expect(notifier.state.messages.last.content, expected);
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.streamingText, isNull);

    // A late flush timer must not resurrect a ghost streaming bubble.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(notifier.state.streamingText, isNull);
  });

  test('trip_updated bumps the counter and flags the turn, reset on next send',
      () async {
    final service = _ScriptedPlanService([
      const PlanEvent(type: 'trip_updated', data: {}),
      const PlanEvent(type: 'trip_updated', data: {}),
      const PlanEvent(type: 'text_delta', data: {'text': 'Swapped it out.'}),
    ]);
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');

    await notifier.sendMessage('replace the museum');
    expect(notifier.state.tripUpdateCount, 2);
    expect(notifier.state.tripUpdatedThisTurn, isTrue);

    // The flag is per-turn; the monotonic counter is not.
    service.events.clear();
    await notifier.sendMessage('thanks');
    expect(notifier.state.tripUpdatedThisTurn, isFalse);
    expect(notifier.state.tripUpdateCount, 2);
  });

  test('retryLastSend re-runs the failed turn with no duplicate user message',
      () async {
    final service = _ScriptedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Half an ans'}),
      const PlanEvent(type: 'error', data: {'message': 'stream died'}),
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    await notifier.sendMessage('plan athens');
    expect(notifier.state.error, 'stream died');
    expect(notifier.state.isStreaming, isFalse);
    // The failed turn kept the user message plus the committed partial reply.
    expect(notifier.state.messages.map((m) => m.role).toList(),
        [MessageRole.user, MessageRole.assistant]);

    // The retry succeeds.
    service.events
      ..clear()
      ..add(const PlanEvent(type: 'text_delta', data: {'text': 'Full answer.'}));
    await notifier.retryLastSend();

    expect(notifier.state.error, isNull);
    // Exactly one copy of the user message; the partial was rolled back and
    // regenerated as a fresh turn.
    final users =
        notifier.state.messages.where((m) => m.role == MessageRole.user);
    expect(users.length, 1);
    expect(users.single.content, 'plan athens');
    expect(notifier.state.messages.last.role, MessageRole.assistant);
    expect(notifier.state.messages.last.content, 'Full answer.');
    // The server payload for the retry carried no duplicate either.
    expect(service.lastHistory!.where((m) => m['role'] == 'user').length, 1);

    // Retry is a no-op when there is nothing to retry.
    await notifier.retryLastSend();
    expect(notifier.state.messages.length, 2);
  });

  test('displayLabel collapses the bubble but the full content reaches history',
      () async {
    final service = _ScriptedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'On it.'}),
    ]);
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');

    const seed = 'I want to refine my saved trip "Athens" ... - Acropolis '
        '[attraction] (37.97, 23.72), day 1, morning';
    await notifier.sendMessage(seed, displayLabel: 'Refining Day 1 — Athens');

    // UI-facing message carries the label; the server history carries the
    // untouched machine seed.
    expect(notifier.state.messages.first.displayLabel, 'Refining Day 1 — Athens');
    expect(notifier.state.messages.first.content, seed);
    expect(service.lastHistory!.first['content'], seed);
    // The label rides along as metadata (titles the persisted session and
    // survives the wholesale transcript upsert on later turns).
    expect(service.lastHistory!.first['display_label'], 'Refining Day 1 — Athens');

    // A plain message carries no display_label key at all.
    service.events
      ..clear()
      ..add(const PlanEvent(type: 'text_delta', data: {'text': 'Sure.'}));
    await notifier.sendMessage('make day 2 chiller');
    expect(service.lastHistory!.last['role'], 'user');
    expect(service.lastHistory!.last.containsKey('display_label'), isFalse);
  });
}
