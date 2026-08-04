import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Contextual send/stop swap: while a turn streams with nothing drafted the
/// send button becomes a stop button; typing a follow-up flips it back to
/// send so queue-ahead keeps working; tapping stop commits the partial reply
/// as a normal bubble and reverts the button.

/// Plays [script] in order: [PlanEvent]s are yielded, [Completer]s are
/// awaited — so a test can park the stream mid-turn and observe the UI.
class _StagedPlanService extends PlanService {
  final List<Object> script;

  _StagedPlanService(this.script) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final step in script) {
      if (step is Completer<void>) {
        await step.future;
      } else {
        yield step as PlanEvent;
      }
    }
  }
}

Future<void> _pumpPanel(WidgetTester tester, _StagedPlanService service) async {
  final notifier = PlanNotifier(service, ApiClient());
  final provider =
      StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
}

Future<void> _send(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'hi');
  await tester.pump();
  await tester.tap(find.byIcon(Icons.send));
  await tester.pump();
}

void main() {
  testWidgets('idle shows send; streaming with an empty composer shows stop',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Hello there'}),
      gate,
    ]);
    await _pumpPanel(tester, service);

    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    // _send clears the composer, so the swap lands the instant a turn starts.
    await _send(tester);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
  });

  testWidgets('typing a follow-up mid-stream flips stop back to send',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Hello there'}),
      gate,
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    expect(find.byIcon(Icons.stop), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'queue this too');
    await tester.pump();
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    // Whitespace is not a draft.
    await tester.enterText(find.byType(TextField), '  ');
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('tapping stop commits the partial bubble and reverts the button',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Hello there'}),
      gate,
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    // Let the 48ms flush render the live streaming bubble first.
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Hello there'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();

    // The partial survives as a committed assistant bubble — no error banner,
    // no ghost streaming bubble later.
    expect(find.text('Hello there'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('Hello there'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
