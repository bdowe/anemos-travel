import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/providers/dictation_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/dictation_controller.dart';
import 'package:travel_route_planner/services/dictation_engine.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

class _FakeEngine implements DictationEngine {
  final bool initOk;
  StreamController<DictationEvent>? _events;

  _FakeEngine({this.initOk = true});

  @override
  Future<bool> initialize() async => initOk;

  @override
  Stream<DictationEvent> start() {
    _events = StreamController<DictationEvent>();
    return _events!.stream;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async => end();

  void emit(DictationEvent event) => _events!.add(event);

  Future<void> end() async {
    final events = _events;
    _events = null;
    if (events != null && !events.isClosed) await events.close();
  }
}

/// Replies instantly with one delta; records sent messages. No network.
class _FakePlanService extends PlanService {
  final sent = <String>[];

  _FakePlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    sent.add(messages.last['content'] ?? '');
    yield PlanEvent(type: 'text_delta', data: {'text': 'ok'});
  }
}

Future<_FakePlanService> _pumpPanel(
  WidgetTester tester, {
  required _FakeEngine engine,
  bool serverAvailable = false,
}) async {
  final service = _FakePlanService();
  final notifier = PlanNotifier(service, ApiClient());
  final provider =
      StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dictationControllerFactoryProvider.overrideWithValue(
          (textController) => DictationController(
            textController: textController,
            primary: engine,
            fallback: null,
            fallbackAvailable: () async => serverAvailable,
          ),
        ),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
  await tester.pump(); // let async engine init resolve
  return service;
}

void main() {
  testWidgets('mic dictates into the field and the send path is the normal one',
      (WidgetTester tester) async {
    final engine = _FakeEngine();
    final service = await _pumpPanel(tester, engine: engine);

    expect(find.byIcon(Icons.mic_none), findsOneWidget);

    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump();
    expect(find.byIcon(Icons.mic), findsOneWidget,
        reason: 'listening state icon');

    engine.emit(const DictationEvent('partial', text: 'three days'));
    await tester.pump();
    expect(find.text('three days'), findsOneWidget);

    engine.emit(const DictationEvent('final', text: 'three days in crete'));
    await engine.end();
    await tester.pump();
    expect(find.byIcon(Icons.mic_none), findsOneWidget, reason: 'back to idle');
    expect(find.text('three days in crete'), findsOneWidget);

    // Nothing was auto-sent; the user sends explicitly.
    expect(service.sent, isEmpty);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(service.sent, ['three days in crete']);
  });

  testWidgets('mic is absent when no dictation path exists',
      (WidgetTester tester) async {
    await _pumpPanel(tester,
        engine: _FakeEngine(initOk: false), serverAvailable: false);
    await tester.pump();

    expect(find.byIcon(Icons.mic_none), findsNothing);
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(find.byIcon(Icons.send), findsOneWidget,
        reason: 'composer otherwise intact');
  });

  testWidgets('transcribing state shows a spinner instead of the mic',
      (WidgetTester tester) async {
    final engine = _FakeEngine();
    await _pumpPanel(tester, engine: engine);

    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump();
    engine.emit(const DictationEvent('transcribing'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing);

    engine.emit(const DictationEvent('final', text: 'hi'));
    await engine.end();
    await tester.pump();
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets('dictation errors surface as a SnackBar, not a chat error',
      (WidgetTester tester) async {
    final engine = _FakeEngine();
    await _pumpPanel(tester, engine: engine);

    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump();
    engine.emit(const DictationEvent('error', errorCode: 'permission'));
    await engine.end();
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Microphone access'), findsOneWidget);
  });
}
