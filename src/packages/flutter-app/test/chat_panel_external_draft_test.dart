import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/dictation_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/dictation_controller.dart';
import 'package:travel_route_planner/services/dictation_engine.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// An EXTERNAL `chatDraftProvider` write reaches a MOUNTED composer
/// (specs/landing-prompt-handoff): the pending-prompt resume writes the draft
/// from outside the panel, possibly after the panel is already up. Before the
/// listener, such a write landed only on the next remount's `_restoreDraft` —
/// a silent-loss window.

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

class _StubPlanService extends PlanService {
  _StubPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    yield PlanEvent(type: 'text_delta', data: {'text': 'ok'});
  }
}

void main() {
  Future<ProviderContainer> pumpPanel(WidgetTester tester) async {
    final notifier = PlanNotifier(_StubPlanService(), ApiClient());
    final provider =
        StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
    await tester.pumpWidget(ProviderScope(
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
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ));
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ChatPanel)));
  }

  TextEditingController composer(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!;

  testWidgets('an external draft write lands in the mounted composer, caret '
      'at the end', (tester) async {
    final container = await pumpPanel(tester);

    container
        .read(chatDraftProvider(chatDraftKeyFor(null)).notifier)
        .setText('A week in Rome');
    await tester.pump();

    final controller = composer(tester);
    expect(controller.text, 'A week in Rome');
    expect(controller.selection.baseOffset, 'A week in Rome'.length);
  });

  testWidgets('typing after an external write round-trips without loops',
      (tester) async {
    final container = await pumpPanel(tester);

    container
        .read(chatDraftProvider(chatDraftKeyFor(null)).notifier)
        .setText('A week in Rome');
    await tester.pump();

    await tester.enterText(
        find.byType(TextField).first, 'A week in Rome in May');
    await tester.pump();

    expect(composer(tester).text, 'A week in Rome in May');
    // The keystroke echoed into the draft (the _saveDraft path still works).
    expect(container.read(chatDraftProvider(chatDraftKeyFor(null))).text,
        'A week in Rome in May');
  });
}
