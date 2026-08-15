import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// appendSectionRefinement is what stopped a ✨ tap from wiping the trip's
/// conversation (specs/trip-refine-memory). Two contracts here:
///
///  1. It appends. Nothing already said is removed.
///  2. It collapses EARLIER seeds' itinerary listings in place, so the agent
///     only ever holds one authoritative listing — and it rewrites content
///     rather than removing messages, because compactedCount is a
///     start-anchored index into `messages`.

class _SilentPlanService extends PlanService {
  final List<List<Map<String, dynamic>>> histories = [];
  _SilentPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    histories.add(messages);
  }
}

const _daySeed = 'The section to refine — Day 3 — Medellín:\n'
    '- Comuna 13 [attraction] (6.24, -75.57), city: Medellín, day 3';
const _citySeed = 'The section to refine — Cartagena:\n'
    '- Getsemaní [attraction] (10.42, -75.55), city: Cartagena, day 5';

void main() {
  test('appending a section keeps the conversation and adds exactly one message',
      () async {
    final service = _SilentPlanService();
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');

    notifier.appendSectionRefinement(_daySeed,
        displayLabel: 'Refining Day 3 — Medellín');
    await Future<void>.delayed(Duration.zero);
    notifier.appendSectionRefinement(_citySeed,
        displayLabel: 'Refining Cartagena');
    await Future<void>.delayed(Duration.zero);

    final messages = notifier.state.messages;
    expect(messages, hasLength(2));
    expect(messages.first.displayLabel, 'Refining Day 3 — Medellín');
    expect(messages.last.displayLabel, 'Refining Cartagena');
  });

  test('an appended seed supersedes the earlier listing, in place', () async {
    final service = _SilentPlanService();
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');

    notifier.appendSectionRefinement(_daySeed,
        displayLabel: 'Refining Day 3 — Medellín');
    await Future<void>.delayed(Duration.zero);
    notifier.appendSectionRefinement(_citySeed,
        displayLabel: 'Refining Cartagena');
    await Future<void>.delayed(Duration.zero);

    final messages = notifier.state.messages;
    // The stale coordinates are gone from the wire…
    expect(messages.first.content, isNot(contains('Comuna 13')));
    expect(messages.first.content, contains('superseded'));
    // …while the chip the reader sees is untouched.
    expect(messages.first.displayLabel, 'Refining Day 3 — Medellín');
    // Only the newest listing survives, and it says the older ones are stale.
    expect(messages.last.content, contains('Getsemaní'));
    expect(messages.last.content, contains('Ignore any earlier itinerary'));

    // What the model actually received on the second turn.
    final sent = service.histories.last;
    expect(sent, hasLength(2));
    expect(sent.first['content'], isNot(contains('Comuna 13')));
    expect(sent.last['content'], contains('Getsemaní'));
  });

  test('ordinary user messages are never stubbed', () async {
    final service = _SilentPlanService();
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');

    notifier.appendSectionRefinement(_daySeed,
        displayLabel: 'Refining Day 3 — Medellín');
    await Future<void>.delayed(Duration.zero);
    notifier.sendMessage('swap the museum for something outdoors');
    await Future<void>.delayed(Duration.zero);
    notifier.appendSectionRefinement(_citySeed,
        displayLabel: 'Refining Cartagena');
    await Future<void>.delayed(Duration.zero);

    final messages = notifier.state.messages;
    expect(messages, hasLength(3));
    // A real thing the traveler said keeps its words, forever.
    expect(messages[1].content, 'swap the museum for something outdoors');
    expect(messages[1].displayLabel, isNull);
    // Indices are preserved — compactedCount counts from the start.
    expect(messages[0].displayLabel, 'Refining Day 3 — Medellín');
    expect(messages[2].displayLabel, 'Refining Cartagena');
  });

  test('stubbing is idempotent — an already-superseded seed is left alone',
      () async {
    final service = _SilentPlanService();
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');

    notifier.appendSectionRefinement(_daySeed,
        displayLabel: 'Refining Day 3 — Medellín');
    await Future<void>.delayed(Duration.zero);
    notifier.appendSectionRefinement(_citySeed, displayLabel: 'Refining Cartagena');
    await Future<void>.delayed(Duration.zero);
    final stubbed = notifier.state.messages.first.content;
    notifier.appendSectionRefinement('third', displayLabel: 'Refining Day 1');
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.messages.first.content, stubbed);
    expect(notifier.state.messages, hasLength(3));
  });

  test('startOver drops the transcript and the chat id', () async {
    final service = _SilentPlanService();
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');

    notifier.appendSectionRefinement(_daySeed, displayLabel: 'Refining Day 3');
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.messages, isNotEmpty);

    notifier.startOver();

    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.chatId, isNull);
  });
}
