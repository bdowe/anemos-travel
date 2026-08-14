import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Tool-chip lifetime and labels (specs/chat-working-indicator): the
/// create_itinerary chip is cleared by `done` (its real result event — the
/// tool suppresses tool_result), and tools without a named label render the
/// localized generic "Working..." — never the raw snake_case name.

/// Plays [script] in order: [PlanEvent]s are yielded, [Completer]s are
/// awaited — same staging harness as chat_panel_typing_indicator_test.dart.
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
  await tester.tap(find.byIcon(Icons.send));
  await tester.pump();
}

void main() {
  testWidgets('done clears the create_itinerary chip',
      (WidgetTester tester) async {
    final afterToolCall = Completer<void>();
    final afterDone = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'tool_call', data: {'name': 'create_itinerary'}),
      afterToolCall,
      const PlanEvent(
          type: 'done', data: {'locations': [], 'summary': 'A trip'}),
      afterDone,
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Building itinerary...'), findsOneWidget);

    afterToolCall.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // No tool_result ever comes for create_itinerary — `done` is its result,
    // and the chip must not keep spinning under the finished banner.
    expect(find.text('Building itinerary...'), findsNothing);
    afterDone.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('unlabeled tools render the generic working label',
      (WidgetTester tester) async {
    final afterToolCall = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'tool_call', data: {'name': 'save_preferences'}),
      afterToolCall,
      const PlanEvent(type: 'tool_result', data: {'name': 'save_preferences'}),
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Working...'), findsOneWidget);
    expect(find.textContaining('save_preferences'), findsNothing);
    afterToolCall.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('newly named tools get their own labels',
      (WidgetTester tester) async {
    final afterToolCall = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(
          type: 'tool_call', data: {'name': 'search_local_recommendations'}),
      afterToolCall,
      const PlanEvent(
          type: 'tool_result', data: {'name': 'search_local_recommendations'}),
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Finding local picks...'), findsOneWidget);
    afterToolCall.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('parallel same-tool calls collapse to one chip',
      (WidgetTester tester) async {
    final afterBothCalls = Completer<void>();
    final afterFirstResult = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'tool_call', data: {'name': 'search_places'}),
      const PlanEvent(type: 'tool_call', data: {'name': 'search_places'}),
      afterBothCalls,
      const PlanEvent(type: 'tool_result', data: {'name': 'search_places'}),
      afterFirstResult,
      const PlanEvent(type: 'tool_result', data: {'name': 'search_places'}),
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump(const Duration(milliseconds: 20));
    // Two parallel search_places blocks announced — one chip, not twins.
    expect(find.text('Searching places...'), findsOneWidget);

    afterBothCalls.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // First result in: one call still running, so the chip stays.
    expect(find.text('Searching places...'), findsOneWidget);

    afterFirstResult.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // Last result clears it.
    expect(find.text('Searching places...'), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('different unlabeled tools share one working chip',
      (WidgetTester tester) async {
    final afterBothCalls = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'tool_call', data: {'name': 'save_preferences'}),
      const PlanEvent(type: 'tool_call', data: {'name': 'set_travel_mode'}),
      afterBothCalls,
      const PlanEvent(type: 'tool_result', data: {'name': 'save_preferences'}),
      const PlanEvent(type: 'tool_result', data: {'name': 'set_travel_mode'}),
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    await tester.pump(const Duration(milliseconds: 20));
    // The dedupe is by rendered label, not tool name: two distinct quick
    // writes both fall back to the generic label and must share a chip.
    expect(find.text('Working...'), findsOneWidget);
    afterBothCalls.complete();
    await tester.pumpAndSettle();
  });
}
