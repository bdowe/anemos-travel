import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// Assistant text on either side of a tool call streams into one buffer; the
/// notifier inserts a paragraph separator at the boundary so the two beats
/// don't render run together ("…committing.Great news…"). These tests pin the
/// insertion rules and that both commit paths see already-separated text.

/// Replays a canned event list, optionally spacing events a couple of
/// milliseconds apart so several 48ms flush windows elapse mid-turn (the
/// real-SSE timing shape used across the plan provider tests).
class _ScriptedPlanService extends PlanService {
  final List<PlanEvent> events;
  final Duration? delay;

  _ScriptedPlanService(this.events, {this.delay}) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final e in events) {
      if (delay != null) await Future<void>.delayed(delay!);
      yield e;
    }
  }
}

PlanEvent _delta(String text) =>
    PlanEvent(type: 'text_delta', data: {'text': text});
const _toolCall = PlanEvent(type: 'tool_call', data: {'name': 'search_flights'});
const _toolResult =
    PlanEvent(type: 'tool_result', data: {'name': 'search_flights'});

Future<PlanNotifier> _run(List<PlanEvent> events, {Duration? delay}) async {
  final notifier =
      PlanNotifier(_ScriptedPlanService(events, delay: delay), ApiClient());
  await notifier.sendMessage('hi');
  return notifier;
}

void main() {
  test('text resuming after a tool call gets a paragraph separator', () async {
    final notifier = await _run([
      _delta('Committing.'),
      _toolCall,
      _toolResult,
      _delta('Great news!'),
    ]);
    expect(notifier.state.messages.last.content, 'Committing.\n\nGreat news!');
  });

  test('a model-supplied newline at the boundary is not doubled', () async {
    final notifier = await _run([
      _delta('Done.'),
      _toolCall,
      _toolResult,
      _delta('\n\nNext.'),
    ]);
    expect(notifier.state.messages.last.content, 'Done.\n\nNext.');
  });

  test('buffer already ending in a newline is not doubled', () async {
    final notifier = await _run([
      _delta('The list:\n'),
      _toolCall,
      _toolResult,
      _delta('Next.'),
    ]);
    expect(notifier.state.messages.last.content, 'The list:\nNext.');
  });

  test('a plain leading space still gets the separator', () async {
    // A space is mid-sentence punctuation, not a paragraph break — the two
    // beats around a tool call are separate thoughts.
    final notifier = await _run([
      _delta('Done.'),
      _toolCall,
      _toolResult,
      _delta(' Now, about hotels'),
    ]);
    expect(notifier.state.messages.last.content, 'Done.\n\n Now, about hotels');
  });

  test('a turn that opens with a tool gets no leading separator', () async {
    final notifier = await _run([
      _toolCall,
      _toolResult,
      _delta('Hello.'),
    ]);
    expect(notifier.state.messages.last.content, 'Hello.');
  });

  test('consecutive tool pairs produce exactly one separator', () async {
    final notifier = await _run([
      _delta('A.'),
      _toolCall,
      _toolResult,
      _toolCall,
      _toolResult,
      _delta('B.'),
    ]);
    expect(notifier.state.messages.last.content, 'A.\n\nB.');
  });

  test('the mid-turn error commit contains the separator', () async {
    final notifier = await _run([
      _delta('Half'),
      _toolCall,
      _toolResult,
      _delta('More'),
      const PlanEvent(type: 'error', data: {'message': 'stream died'}),
    ]);
    expect(notifier.state.error, 'stream died');
    expect(notifier.state.messages.last.role, MessageRole.assistant);
    expect(notifier.state.messages.last.content, 'Half\n\nMore');
  });

  test('separator survives real flush timing with no double insert', () async {
    // 6ms-apart events: the ten post-boundary deltas span ~60ms, so the 48ms
    // flush timer provably fires while they are still streaming (delays never
    // complete early) — the separator must already be in the timer-flushed
    // streamingText, not only in the final commit.
    final events = [
      for (var i = 0; i < 10; i++) _delta('a$i '),
      _toolCall,
      _toolResult,
      for (var i = 0; i < 10; i++) _delta('b$i '),
    ];
    final notifier = PlanNotifier(
        _ScriptedPlanService(events, delay: const Duration(milliseconds: 6)),
        ApiClient());
    final midStream = <String>[];
    notifier.addListener((state) {
      final t = state.streamingText;
      if (t != null && t.isNotEmpty) midStream.add(t);
    });
    await notifier.sendMessage('hi');

    final before = List.generate(10, (i) => 'a$i ').join();
    final after = List.generate(10, (i) => 'b$i ').join();
    // A mid-stream timer flush saw the separated text, exactly once.
    expect(midStream.where((t) => t.contains('\n\n')), isNotEmpty);
    expect(midStream.any((t) => t.contains('\n\n\n')), isFalse);
    expect(notifier.state.messages.last.content, '$before\n\n$after');
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.streamingText, isNull);

    // A late flush timer must not resurrect a ghost streaming bubble.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(notifier.state.streamingText, isNull);
  });
}
