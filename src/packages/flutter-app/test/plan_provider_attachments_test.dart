import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// Image attachments through the provider (specs/chat-image-attachments):
/// the wire history carries base64 `images` for byte-bearing attachments —
/// on the sending turn AND on later turns' history resend — through the
/// queue and retry paths; resume placeholders (null bytes) never serialize.
class _RecordingPlanService extends PlanService {
  final List<List<Map<String, dynamic>>> histories = [];
  Completer<void>? gate;
  bool failNext = false;

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

void main() {
  final bytes = Uint8List.fromList([1, 2, 3, 4]);
  final attachment = PlanAttachment(bytes: bytes, mediaType: 'image/png');
  final expectedImage = {
    'media_type': 'image/png',
    'data': base64Encode(bytes),
  };

  test('attachments serialize as images on the turn and on history resend',
      () async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    await notifier.sendMessage('where is this?', attachments: [attachment]);
    await notifier.sendMessage('and how do I get there?');

    final firstTurn = service.histories[0];
    expect(firstTurn.single['images'], [expectedImage]);

    // Second turn resends the whole history: the image rides along again.
    final secondTurn = service.histories[1];
    expect(secondTurn[0]['images'], [expectedImage]);
    expect(secondTurn[1], isNot(contains('images'))); // assistant reply
    expect(secondTurn[2], isNot(contains('images'))); // new text-only message
  });

  test('image-only send (empty text) carries the attachment', () async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    await notifier.sendMessage('', attachments: [attachment]);

    expect(service.histories.single.single['content'], '');
    expect(service.histories.single.single['images'], [expectedImage]);
    expect(notifier.state.messages.first.attachments, hasLength(1));
  });

  test('queued-while-streaming messages keep their attachments', () async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    final gate = Completer<void>();
    service.gate = gate;
    final first = notifier.sendMessage('a');
    await notifier.sendMessage('look at this', attachments: [attachment]);
    expect(notifier.state.queuedMessages.single.attachments, hasLength(1));

    gate.complete();
    await first;

    expect(service.histories, hasLength(2));
    final drained = service.histories[1];
    expect(drained.last['content'], 'look at this');
    expect(drained.last['images'], [expectedImage]);
  });

  test('retryLastSend re-sends the failed message with its attachments',
      () async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    service.failNext = true;
    await notifier.sendMessage('what city?', attachments: [attachment]);
    expect(notifier.state.error, 'boom');

    await notifier.retryLastSend();

    expect(notifier.state.error, isNull);
    final retried = service.histories[1];
    final userTurns =
        retried.where((m) => m['role'] == 'user').toList();
    expect(userTurns, hasLength(1));
    expect(userTurns.single['images'], [expectedImage]);
    // The transcript keeps exactly one copy of the message, with attachments.
    expect(
        notifier.state.messages
            .where((m) => m.role == MessageRole.user)
            .single
            .attachments,
        hasLength(1));
  });

  test('resume placeholders (null bytes) never serialize into the history',
      () async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    notifier.resumeConversation(
      chatId: 'chat-resumed',
      messages: [
        PlanMessage(
          role: MessageRole.user,
          content: 'where is this beach?',
          attachments: [PlanAttachment(bytes: null, mediaType: 'image/jpeg')],
        ),
        const PlanMessage(role: MessageRole.assistant, content: 'The Algarve!'),
      ],
    );
    await notifier.sendMessage('plan two days there');

    final history = service.histories.single;
    expect(history, hasLength(3));
    expect(history[0], isNot(contains('images')));
  });

  test('a message mixing real and placeholder attachments sends only the real one',
      () async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());

    await notifier.sendMessage('both kinds', attachments: [
      PlanAttachment(bytes: null, mediaType: 'image/jpeg'),
      attachment,
    ]);

    expect(service.histories.single.single['images'], [expectedImage]);
  });
}
