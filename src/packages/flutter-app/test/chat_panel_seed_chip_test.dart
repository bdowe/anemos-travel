import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Replays a canned event list; no network.
class _ScriptedPlanService extends PlanService {
  final List<PlanEvent> events;

  _ScriptedPlanService(this.events) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final e in events) {
      yield e;
    }
  }
}

void main() {
  testWidgets(
      'seed collapses to a context chip and trip_updated shows the ack chip',
      (WidgetTester tester) async {
    final service = _ScriptedPlanService([
      const PlanEvent(type: 'trip_updated', data: {}),
      const PlanEvent(type: 'text_delta', data: {'text': 'Swapped it out.'}),
    ]);
    final notifier = PlanNotifier(service, ApiClient(), tripId: 't1');
    final provider =
        StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);

    const seed = 'I want to refine my saved trip "Athens & Santorini". '
        '- Acropolis [attraction] (37.9715, 23.7257), city: Athens, day 1';
    notifier.beginSectionRefinement(seed,
        displayLabel: 'Refining Day 1 — Athens');

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
    await tester.pumpAndSettle();

    // The machine seed renders as a compact session marker, not a bubble.
    expect(find.text('Refining Day 1 — Athens'), findsOneWidget);
    expect(find.textContaining('37.9715'), findsNothing);
    expect(find.textContaining('I want to refine'), findsNothing);

    // The turn patched the trip, so the acknowledgment chip is visible.
    expect(find.text('Trip updated'), findsOneWidget);
  });
}
