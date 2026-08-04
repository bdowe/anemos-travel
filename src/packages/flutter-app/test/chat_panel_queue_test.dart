import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Yields one text_delta per call ('reply N'), parking on [gate] after the
/// delta when set so tests can interact mid-stream. No network.
class _GatedPlanService extends PlanService {
  int calls = 0;

  /// Consumed by the next call: the stream parks on it after its first delta.
  Completer<void>? gate;

  _GatedPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    final call = calls++;
    yield PlanEvent(type: 'text_delta', data: {'text': 'reply $call'});
    final parked = gate;
    gate = null;
    if (parked != null) await parked.future;
  }
}

Future<StateNotifierProvider<PlanNotifier, PlanState>> _pumpPanel(
    WidgetTester tester, _GatedPlanService service) async {
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
  return provider;
}

void main() {
  testWidgets('input stays enabled mid-stream; sends queue and are removable',
      (WidgetTester tester) async {
    final service = _GatedPlanService();
    final gate = Completer<void>();
    service.gate = gate;
    await _pumpPanel(tester, service);

    await tester.enterText(find.byType(TextField), 'plan athens');
    await tester.tap(find.byIcon(Icons.send));
    // Start the stream and let the 48ms token flush land.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // Mid-stream the input is still usable, with the follow-up hint.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isNot(false));
    expect(field.decoration?.hintText, 'Ask a follow-up…');

    await tester.enterText(find.byType(TextField), 'also add delphi');
    // Mid-stream the empty-composer button is Stop; typing flips it back to
    // send on the next frame (contextual send/stop swap).
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('also add delphi'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);

    // The queued bubble's close affordance removes it before it sends.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Queued'), findsNothing);
    expect(find.text('also add delphi'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('reply 0'), findsOneWidget);
    expect(service.calls, 1);
  });

  testWidgets('a queued message auto-sends when the turn completes',
      (WidgetTester tester) async {
    final service = _GatedPlanService();
    final gate = Completer<void>();
    service.gate = gate;
    await _pumpPanel(tester, service);

    await tester.enterText(find.byType(TextField), 'plan athens');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'also add delphi');
    // Contextual swap: a frame must render for Stop to flip back to send.
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(find.text('Queued'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    // The queued bubble became a committed user turn with its own reply.
    expect(find.text('Queued'), findsNothing);
    expect(find.text('also add delphi'), findsOneWidget);
    expect(find.text('reply 0'), findsOneWidget);
    expect(find.text('reply 1'), findsOneWidget);
    expect(service.calls, 2);
  });
}
