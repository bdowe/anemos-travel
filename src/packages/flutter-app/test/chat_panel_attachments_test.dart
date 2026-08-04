import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/dictation_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/dictation_controller.dart';
import 'package:travel_route_planner/services/dictation_engine.dart';
import 'package:travel_route_planner/services/image_attachment_pipeline.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Composer image attachments (specs/chat-image-attachments): chips appear
/// and are removable, sends carry/clear them, image-only sends work, the
/// 4-image cap and unreadable files surface as SnackBars. Files enter through
/// the injected [ChatPanel.pickImages] seam — the same `_addFiles` intake
/// drag-drop uses, whose HTML drop events widget tests can't synthesize.

/// A 1×1 PNG — real bytes for Image.memory to render in chips and bubbles.
final tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// Stands in for the real pipeline: engine image decoding can't complete
/// inside a widget test's fake-async zone (see
/// image_attachment_pipeline_test.dart for the real pipeline's coverage).
/// Echoes bytes through unchanged; "images" shorter than 8 bytes reject.
class _EchoPipeline extends ImageAttachmentPipeline {
  const _EchoPipeline();

  @override
  Future<PlanAttachment?> process(Uint8List bytes, String mediaType) async {
    if (bytes.length < 8) return null;
    return PlanAttachment(bytes: bytes, mediaType: mediaType);
  }
}

class _NoDictationEngine implements DictationEngine {
  @override
  Future<bool> initialize() async => false;
  @override
  Stream<DictationEvent> start() => const Stream.empty();
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

/// Replies instantly with one delta; records every history payload.
class _RecordingPlanService extends PlanService {
  final List<List<Map<String, dynamic>>> histories = [];

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
    yield PlanEvent(type: 'text_delta', data: {'text': 'ok'});
  }
}

class _Harness {
  final _RecordingPlanService service;
  final PlanNotifier notifier;

  /// Consumed by the next paperclip tap.
  List<(Uint8List, String)> nextPick = [];

  _Harness._(this.service, this.notifier);

  static Future<_Harness> build(WidgetTester tester) async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());
    final provider =
        StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
    final harness = _Harness._(service, notifier);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dictationControllerFactoryProvider.overrideWithValue(
            (textController) => DictationController(
              textController: textController,
              primary: _NoDictationEngine(),
              fallback: null,
              fallbackAvailable: () async => false,
            ),
          ),
        ],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
          home: Scaffold(
            body: ChatPanel(
              state: provider,
              notifier: provider.notifier,
              attachmentPipeline: const _EchoPipeline(),
              pickImages: () async => harness.nextPick,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return harness;
  }
}

Future<void> _attach(
    WidgetTester tester, _Harness harness, List<(Uint8List, String)> files) async {
  harness.nextPick = files;
  await tester.tap(find.byIcon(Icons.attach_file));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('attach shows a chip; send carries the image and clears chips',
      (tester) async {
    final harness = await _Harness.build(tester);

    await _attach(tester, harness, [(tinyPng, 'image/png')]);
    expect(find.byType(Image), findsOneWidget, reason: 'pending chip');

    await tester.enterText(find.byType(TextField), 'where is this?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    final sent = harness.service.histories.single.single;
    expect(sent['content'], 'where is this?');
    expect((sent['images'] as List).single['media_type'], 'image/png');
    expect((sent['images'] as List).single['data'], base64Encode(tinyPng));

    // Chips row is gone; the sent bubble now shows the thumbnail.
    expect(
        harness.notifier.state.messages.first.attachments, hasLength(1));
    expect(find.byType(Image), findsOneWidget, reason: 'bubble thumbnail');
  });

  testWidgets('the ✕ removes a pending image before send', (tester) async {
    final harness = await _Harness.build(tester);

    await _attach(tester, harness, [(tinyPng, 'image/png')]);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(Image), findsNothing);

    await tester.enterText(find.byType(TextField), 'no image after all');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(harness.service.histories.single.single,
        isNot(contains('images')));
  });

  testWidgets('an image-only send is allowed', (tester) async {
    final harness = await _Harness.build(tester);

    // Send with nothing at all: no-op.
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(harness.service.histories, isEmpty);

    await _attach(tester, harness, [(tinyPng, 'image/png')]);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    final sent = harness.service.histories.single.single;
    expect(sent['content'], '');
    expect(sent['images'], hasLength(1));
  });

  testWidgets('a fifth image is rejected with a notice', (tester) async {
    final harness = await _Harness.build(tester);

    await _attach(tester, harness,
        List.filled(5, (tinyPng, 'image/png')));

    expect(find.byType(Image), findsNWidgets(4));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('up to 4 images'), findsOneWidget);
  });

  testWidgets('an unreadable file surfaces a notice, not a chip',
      (tester) async {
    final harness = await _Harness.build(tester);

    await _attach(tester, harness, [
      (Uint8List.fromList([1, 2, 3]), 'image/png'),
    ]);

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining("Couldn't read that image"), findsOneWidget);
  });

  testWidgets('resumed placeholder attachments render an Image chip',
      (tester) async {
    final harness = await _Harness.build(tester);

    harness.notifier.resumeConversation(
      chatId: 'chat-resumed',
      messages: [
        PlanMessage(
          role: MessageRole.user,
          content: 'where is this beach?',
          attachments: [PlanAttachment(bytes: null, mediaType: 'image/jpeg')],
        ),
        const PlanMessage(role: MessageRole.assistant, content: 'The Algarve.'),
      ],
    );
    await tester.pump();

    expect(find.text('Image'), findsOneWidget, reason: 'placeholder chip');
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing, reason: 'no pixels to render');
  });
}
