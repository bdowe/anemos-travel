import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';
import 'package:travel_route_planner/widgets/result_summary_chip.dart';

import 'support/l10n_test_app.dart';

/// Chat bubbles span 78% of the hosting panel's own width — not the window —
/// capping at 720px on wide panels, keeping line lengths readable. Covers the
/// full-width phone/desktop hosts plus the 400px refine-dock host. Plus the
/// es spot-check for the result chip's newly localized "View in trip" label.

class _SeededPlanNotifier extends PlanNotifier {
  _SeededPlanNotifier(PlanState seeded)
      : super(PlanService('http://unused'), ApiClient()) {
    state = seeded;
  }
}

Future<void> _pumpLongMessageAt(
  WidgetTester tester,
  Size logicalSize, {
  double? hostWidth,
}) async {
  tester.view.physicalSize = logicalSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final seeded = PlanState(messages: [
    PlanMessage(role: MessageRole.assistant, content: 'word ' * 200),
  ]);
  final provider = StateNotifierProvider<PlanNotifier, PlanState>(
      (ref) => _SeededPlanNotifier(seeded));
  Widget panel = ChatPanel(state: provider, notifier: provider.notifier);
  if (hostWidth != null) {
    // Mimics the trip-detail refine dock: a fixed-width panel pinned to the
    // right edge of a much wider window.
    panel = Align(
      alignment: Alignment.centerRight,
      child: SizedBox(width: hostWidth, child: panel),
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      child: localizedTestApp(
        home: Scaffold(body: panel),
      ),
    ),
  );
}

double _bubbleMaxWidth(WidgetTester tester) {
  // The bubble's outer Container carries the width constraint; it is the
  // first Container inside ChatMessageBubble in build order.
  final container = tester.widget<Container>(find
      .descendant(
        of: find.byType(ChatMessageBubble),
        matching: find.byType(Container),
      )
      .first);
  return container.constraints!.maxWidth;
}

void main() {
  testWidgets('bubbles cap at 720 on a wide desktop window',
      (WidgetTester tester) async {
    await _pumpLongMessageAt(tester, const Size(2400, 1000));
    expect(_bubbleMaxWidth(tester), 720);
  });

  testWidgets('bubbles keep the 78% constraint on narrow screens',
      (WidgetTester tester) async {
    await _pumpLongMessageAt(tester, const Size(400, 800));
    expect(_bubbleMaxWidth(tester), closeTo(312, 0.01));
  });

  testWidgets('bubbles size to the hosting panel, not the window (400px dock)',
      (WidgetTester tester) async {
    await _pumpLongMessageAt(tester, const Size(1200, 900), hostWidth: 400);
    // 0.78 × the dock's own 400px — were the cap still window-derived,
    // 0.78 × 1200 would blow past the dock and clamp bubbles to its full
    // width (the pre-fix regression).
    expect(_bubbleMaxWidth(tester), closeTo(312, 0.01));
  });

  testWidgets('result chip "View in trip" label is localized (es)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      localizedTestApp(
        locale: const Locale('es'),
        home: Scaffold(
          body: ResultSummaryChip(
            icon: Icons.flight,
            accent: Colors.blue,
            label: '3 vuelos',
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Ver en el viaje'), findsOneWidget);
  });
}
