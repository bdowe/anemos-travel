import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// Records every streamPlan call (history, chatId, summary) and replies with
/// one text delta — the seam for asserting what a resumed session sends.
class _RecordingPlanService extends PlanService {
  final List<List<Map<String, dynamic>>> histories = [];
  final List<String?> chatIds = [];
  final List<String?> summaries = [];

  _RecordingPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    histories.add(List.of(messages));
    chatIds.add(chatId);
    summaries.add(summary);
    yield const PlanEvent(type: 'text_delta', data: {'text': 'reply'});
  }
}

void main() {
  group('resumeConversation', () {
    test('hydrates the transcript with no network call', () {
      final service = _RecordingPlanService();
      final notifier = PlanNotifier(service, ApiClient());

      notifier.resumeConversation(
        chatId: 'chat-restored',
        messages: const [
          PlanMessage(role: MessageRole.user, content: 'Portugal in May?'),
          PlanMessage(role: MessageRole.assistant, content: 'Great choice.'),
        ],
      );

      expect(service.histories, isEmpty);
      expect(notifier.state.messages.map((m) => m.content).toList(),
          ['Portugal in May?', 'Great choice.']);
      expect(notifier.state.isStreaming, isFalse);
    });

    test('next send reuses the resumed chat_id and carries the full history',
        () async {
      final service = _RecordingPlanService();
      final notifier = PlanNotifier(service, ApiClient());

      notifier.resumeConversation(
        chatId: 'chat-restored',
        messages: const [
          PlanMessage(role: MessageRole.user, content: 'u1'),
          PlanMessage(role: MessageRole.assistant, content: 'a1'),
        ],
      );
      await notifier.sendMessage('u2');

      expect(service.chatIds, ['chat-restored']);
      expect(
        service.histories.single.map((m) => m['content']).toList(),
        ['u1', 'a1', 'u2'],
      );
    });

    test('restored compaction summary rides the next send', () async {
      final service = _RecordingPlanService();
      final notifier = PlanNotifier(service, ApiClient());

      notifier.resumeConversation(
        chatId: 'chat-compacted',
        summary: '- travelers: 3',
        messages: const [
          PlanMessage(role: MessageRole.user, content: 'kept tail'),
        ],
      );
      await notifier.sendMessage('next');

      expect(notifier.state.compactedSummary, '- travelers: 3');
      expect(service.summaries, ['- travelers: 3']);
    });

    test('resumed display label survives into the next wire history', () async {
      final service = _RecordingPlanService();
      final notifier = PlanNotifier(service, ApiClient());

      notifier.resumeConversation(
        chatId: 'chat-near-me',
        messages: const [
          PlanMessage(
            role: MessageRole.user,
            content: 'My current location is latitude 40.7234, longitude '
                '-73.9938 (accuracy about 12 m). What is good near me?',
            displayLabel: 'Near my current location',
          ),
          PlanMessage(role: MessageRole.assistant, content: 'You are in NoLita.'),
        ],
      );
      await notifier.sendMessage('anything with live music?');

      // The transcript is upserted wholesale server-side each turn, so the
      // label must ride every resend or the persisted copy loses it.
      final history = service.histories.single;
      expect(history.first['display_label'], 'Near my current location');
      expect(history.last.containsKey('display_label'), isFalse);
    });

    test('empty summary is not restored as compaction state', () {
      final notifier = PlanNotifier(_RecordingPlanService(), ApiClient());
      notifier.resumeConversation(
        chatId: 'chat-plain',
        summary: '',
        messages: const [
          PlanMessage(role: MessageRole.user, content: 'hello'),
        ],
      );
      expect(notifier.state.compactedSummary, isNull);
    });
  });

  group('chat session models', () {
    test('summary round-trips its JSON shape', () {
      final json = {
        'chat_id': 'chat-1',
        'title': 'Portugal in May?',
        'preview': 'Great choice.',
        'message_count': 4,
        'created_at': '2026-07-14T10:00:00Z',
        'updated_at': '2026-07-14T11:30:00Z',
      };
      final summary = ChatSessionSummary.fromJson(json);
      expect(summary.chatId, 'chat-1');
      expect(summary.messageCount, 4);
      expect(summary.toJson(), json);
    });

    test('detail parses ordered messages and summary', () {
      final detail = ChatSessionDetail.fromJson({
        'chat_id': 'chat-1',
        'title': 'Portugal in May?',
        'summary': '- travelers: 3',
        'messages': [
          {'role': 'user', 'content': 'u1'},
          {'role': 'assistant', 'content': 'a1'},
        ],
        'updated_at': '2026-07-14T11:30:00Z',
      });
      expect(detail.summary, '- travelers: 3');
      expect(detail.messages.map((m) => m.role).toList(),
          ['user', 'assistant']);
      expect(detail.messages.last.content, 'a1');
    });

    test('message display_label parses when present and defaults to null', () {
      final labeled = ChatSessionMessage.fromJson({
        'role': 'user',
        'content': 'My current location is latitude 40.7, longitude -73.9',
        'display_label': 'Near my current location',
      });
      expect(labeled.displayLabel, 'Near my current location');

      final plain = ChatSessionMessage.fromJson({
        'role': 'user',
        'content': 'plain question',
      });
      expect(plain.displayLabel, isNull);
    });
  });
}
