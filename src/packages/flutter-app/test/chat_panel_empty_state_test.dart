import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// The Plan tab's empty state joins the composer into one block on a field
/// tall enough to hold it, and keeps the composer on the floor below that.
/// These assert STRUCTURE and WHICH BRANCH is taken — never positions: this
/// suite loads no fonts, so its text metrics are fiction and every number
/// that matters was measured in the browser instead (1440x900 joined,
/// 390x844 joined, 1440x600 floor, non-empty floor).

class _SeededPlanNotifier extends PlanNotifier {
  _SeededPlanNotifier(PlanState seeded)
      : super(PlanService('http://unused'), ApiClient()) {
    state = seeded;
  }
}

/// The joined branch places the [intro, gap, composer] group with an Align
/// whose y splits the leftover air 4:3. Private to chat_panel.dart, so the
/// branch is detected by the alignment value itself.
final _joinBias = Alignment(0, 1 / 7);

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  PlanState? seeded,
  Widget? emptyState,

  /// The field height the block claims to need. Passed explicitly so these
  /// stay structure tests: the real screen derives this from measured text,
  /// and text measured in this suite is fiction.
  double? joinFloor,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final provider = StateNotifierProvider<PlanNotifier, PlanState>(
      (ref) => _SeededPlanNotifier(seeded ?? PlanState()));
  await tester.pumpWidget(
    ProviderScope(
      child: localizedTestApp(
        home: Scaffold(
          body: ChatPanel(
            state: provider,
            notifier: provider.notifier,
            emptyStateBuilder:
                emptyState == null ? null : (context, panel) => emptyState,
            emptyStateJoinFloor:
                emptyState == null ? null : (context, panel) => joinFloor ?? 650,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _joinAlign() => find.byWidgetPredicate(
      (w) => w is Align && w.alignment == _joinBias,
    );

void main() {
  testWidgets('tall field: empty state and composer join as one group',
      (tester) async {
    await _pump(tester, const Size(800, 900),
        emptyState: const Text('INTRO-BLOCK'));

    expect(find.text('INTRO-BLOCK'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(_joinAlign(), findsOneWidget);
  });

  testWidgets('short field: composer keeps the floor, intro scrolls',
      (tester) async {
    await _pump(tester, const Size(800, 500),
        emptyState: const Text('INTRO-BLOCK'));

    expect(find.text('INTRO-BLOCK'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(_joinAlign(), findsNothing);
  });

  testWidgets('a block that composes smaller is joined on that same field',
      (tester) async {
    // The mobile-web fix in one assertion: the field is the 500px that the
    // test above sends to the floor, and the only thing that changed is the
    // block reporting it needs 420. A single constant here could not tell
    // those two cases apart, so every phone got the floor.
    await _pump(tester, const Size(800, 500),
        emptyState: const Text('INTRO-BLOCK'), joinFloor: 420);

    expect(find.text('INTRO-BLOCK'), findsOneWidget);
    expect(_joinAlign(), findsOneWidget);
  });

  testWidgets('a field below even the smallest composition keeps the floor',
      (tester) async {
    // An open keyboard, or the largest accessibility text scales.
    await _pump(tester, const Size(800, 300),
        emptyState: const Text('INTRO-BLOCK'), joinFloor: 420);

    expect(find.text('INTRO-BLOCK'), findsOneWidget);
    expect(_joinAlign(), findsNothing);
  });

  testWidgets('empty without an emptyState (the refine dock) never joins',
      (tester) async {
    await _pump(tester, const Size(800, 900));

    expect(find.byType(TextField), findsOneWidget);
    expect(_joinAlign(), findsNothing);
  });

  testWidgets('a non-empty panel keeps the transcript and the floor composer',
      (tester) async {
    await _pump(
      tester,
      const Size(800, 900),
      seeded: PlanState(messages: [
        PlanMessage(role: MessageRole.user, content: 'Weekend in Lisbon'),
      ]),
      emptyState: const Text('INTRO-BLOCK'),
    );

    expect(find.text('INTRO-BLOCK'), findsNothing);
    expect(find.text('Weekend in Lisbon'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(_joinAlign(), findsNothing);
  });
}
