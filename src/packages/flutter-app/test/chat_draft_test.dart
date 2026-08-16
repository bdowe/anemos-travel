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

/// The composer keeps what you composed and did not send.
///
/// The panel is destroyed by the ordinary gestures of using it — closing the
/// trip's refine panel, and the trip body re-inflating when it opens or
/// crosses the docked width — so the draft lives in [chatDraftProvider], not
/// in the widget. `trip_detail_chat_back_test.dart` covers the real close and
/// reopen; this file covers the unit: unmount, remount, what comes back.

final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// Engine decoding never completes in a widget test's fake-async zone; echo
/// the bytes through instead (same seam `chat_panel_attachments_test` uses).
class _EchoPipeline extends ImageAttachmentPipeline {
  const _EchoPipeline();

  @override
  Future<PlanAttachment?> process(Uint8List bytes, String mediaType) async =>
      PlanAttachment(bytes: bytes, mediaType: mediaType);
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

/// A chat that can be taken away and put back **inside one `ProviderScope`**.
/// A second `pumpWidget` with a fresh scope would build a new
/// `ProviderContainer` and pass against the un-fixed code; the container has
/// to be the same one throughout. Mirrors the real cause: trip detail's body
/// returns a differently-typed widget once the panel opens, so the whole
/// subtree — panel included — is re-inflated.
class _Mountable extends StatefulWidget {
  final StateNotifierProvider<PlanNotifier, PlanState> provider;
  final List<(Uint8List, String)> Function() pick;

  const _Mountable({required this.provider, required this.pick});

  @override
  State<_Mountable> createState() => _MountableState();
}

class _MountableState extends State<_Mountable> {
  bool _shown = true;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          TextButton(
            onPressed: () => setState(() => _shown = !_shown),
            child: const Text('toggle'),
          ),
          if (_shown)
            Expanded(
              child: ChatPanel(
                state: widget.provider,
                notifier: widget.provider.notifier,
                attachmentPipeline: const _EchoPipeline(),
                pickImages: () async => widget.pick(),
              ),
            ),
        ],
      );
}

class _Harness {
  final _RecordingPlanService service;
  final PlanNotifier notifier;
  List<(Uint8List, String)> nextPick = [];

  _Harness._(this.service, this.notifier);

  /// [tripIds] builds one chat per id; a null id is the unbound Agent tab.
  static Future<List<_Harness>> build(
    WidgetTester tester, {
    List<String?> tripIds = const [null],
  }) async {
    final harnesses = <_Harness>[];
    final panels = <Widget>[];
    for (final tripId in tripIds) {
      final service = _RecordingPlanService();
      final notifier = PlanNotifier(service, ApiClient(), tripId: tripId);
      final harness = _Harness._(service, notifier);
      harnesses.add(harness);
      final provider =
          StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
      panels.add(Expanded(
        child: _Mountable(provider: provider, pick: () => harness.nextPick),
      ));
    }
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
          home: Scaffold(body: Column(children: panels)),
        ),
      ),
    );
    await tester.pump();
    return harnesses;
  }
}

/// Take the [index]th chat away and put it back — one unmount/remount trip.
Future<void> _remount(WidgetTester tester, {int index = 0}) async {
  final toggle = find.text('toggle').at(index);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

Future<void> _attach(WidgetTester tester, _Harness harness) async {
  harness.nextPick = [(_tinyPng, 'image/png')];
  await tester.tap(find.byIcon(Icons.attach_file));
  await tester.pumpAndSettle();
}

TextEditingController _composerAt(WidgetTester tester, int index) =>
    tester.widget<TextField>(find.byType(TextField).at(index)).controller!;

void main() {
  testWidgets('an unsent message survives the panel being torn down',
      (tester) async {
    await _Harness.build(tester);

    await tester.enterText(
        find.byType(TextField), 'what else is near the Rijksmuseum?');
    await _remount(tester);

    expect(_composerAt(tester, 0).text, 'what else is near the Rijksmuseum?');
  });

  testWidgets('so do the images attached to it', (tester) async {
    final harness = (await _Harness.build(tester)).single;

    await _attach(tester, harness);
    expect(find.byType(Image), findsOneWidget, reason: 'pending chip');

    await _remount(tester);

    expect(find.byType(Image), findsOneWidget, reason: 'chip is back');
    // And it is still a real attachment, not a placeholder: it sends.
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    final sent = harness.service.histories.single.single;
    expect((sent['images'] as List).single['data'], base64Encode(_tinyPng));
  });

  testWidgets('the restored text can be typed onto, not in front of',
      (tester) async {
    await _Harness.build(tester);

    await tester.enterText(find.byType(TextField), 'two nights in Naxos');
    await _remount(tester);

    // Assigning `controller.text` would park the selection at -1, which the
    // engine normalizes to 0 — the next keystroke would land at the front.
    expect(_composerAt(tester, 0).selection.baseOffset,
        'two nights in Naxos'.length);
  });

  testWidgets('removing an attachment before the panel closes sticks',
      (tester) async {
    final harness = (await _Harness.build(tester)).single;

    await _attach(tester, harness);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    await _remount(tester);

    expect(find.byType(Image), findsNothing);
  });

  testWidgets('sending clears the draft, text and images alike',
      (tester) async {
    final harness = (await _Harness.build(tester)).single;

    await _attach(tester, harness);
    await tester.enterText(find.byType(TextField), 'this one?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    await _remount(tester);

    expect(_composerAt(tester, 0).text, isEmpty);
    // The bubble's own thumbnail is in the transcript; no pending chip.
    expect(harness.notifier.state.messages.first.attachments, hasLength(1));
    expect(find.byIcon(Icons.close), findsNothing, reason: 'no pending chip');
  });

  testWidgets('a trip chat and the Agent tab keep separate drafts',
      (tester) async {
    await _Harness.build(tester, tripIds: const [null, 'trip-1']);

    await tester.enterText(find.byType(TextField).at(1), 'about this trip');
    // The unbound chat writes LAST: on one shared key its text is what the
    // trip's composer would come back holding.
    await tester.enterText(find.byType(TextField).at(0), 'unbound');
    await tester.pumpAndSettle();

    await _remount(tester, index: 1);

    expect(_composerAt(tester, 1).text, 'about this trip');
    expect(_composerAt(tester, 0).text, 'unbound');
  });

  testWidgets('two trips do not share one draft', (tester) async {
    await _Harness.build(tester, tripIds: const ['trip-1', 'trip-2']);

    await tester.enterText(find.byType(TextField).at(0), 'Amsterdam plans');
    await tester.pumpAndSettle();

    // Only a remount re-reads the draft, so only a remount can catch a key
    // that does not distinguish the two trips.
    await _remount(tester, index: 1);

    expect(_composerAt(tester, 1).text, isEmpty);
  });

  test('the draft key is the conversation\'s own identity', () {
    // Not a second identity a host could get wrong: null is the Agent tab,
    // anything else is that trip.
    expect(chatDraftKeyFor(null), 'agent');
    expect(chatDraftKeyFor('trip-1'), 'trip:trip-1');
    expect(chatDraftKeyFor('trip-1') == chatDraftKeyFor('trip-2'), isFalse);
  });
}
