import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:travel_route_planner/models/agent_place.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';
import 'package:travel_route_planner/widgets/place_photo_card.dart';

import 'support/l10n_test_app.dart';

/// Chat transcripts are wrapped in a SelectionArea so text can be highlighted
/// and copied (friction-log item: nothing in a conversation was copyable).
/// The composer's TextField stays OUTSIDE the wrap — it has native selection
/// and nesting it would double-handle gestures.

class _SeededPlanNotifier extends PlanNotifier {
  _SeededPlanNotifier(PlanState seeded)
      : super(PlanService('http://unused'), ApiClient()) {
    state = seeded;
  }
}

Future<void> _pumpSeededChat(WidgetTester tester, PlanState seeded) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final provider = StateNotifierProvider<PlanNotifier, PlanState>(
      (ref) => _SeededPlanNotifier(seeded));
  await tester.pumpWidget(
    ProviderScope(
      child: localizedTestApp(
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('message bubbles sit inside a SelectionArea',
      (WidgetTester tester) async {
    await _pumpSeededChat(
      tester,
      PlanState(messages: [
        PlanMessage(role: MessageRole.user, content: 'hello'),
        PlanMessage(role: MessageRole.assistant, content: 'world'),
      ]),
    );

    expect(
      find.ancestor(
        of: find.byType(ChatMessageBubble),
        matching: find.byType(SelectionArea),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('the composer TextField stays outside the SelectionArea',
      (WidgetTester tester) async {
    await _pumpSeededChat(
      tester,
      PlanState(messages: [
        PlanMessage(role: MessageRole.assistant, content: 'world'),
      ]),
    );

    expect(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(SelectionArea),
      ),
      findsNothing,
    );
  });

  testWidgets('drag-selecting an assistant reply and pressing Ctrl+C copies it',
      (WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpSeededChat(
      tester,
      PlanState(messages: [
        PlanMessage(
            role: MessageRole.assistant,
            content: 'Lisbon is lovely in October.'),
      ]),
    );

    // Mouse drag across the rendered markdown, like a user highlighting it.
    final markdown = find.byType(GptMarkdown);
    final gesture = await tester.startGesture(
      tester.getTopLeft(markdown) + const Offset(2, 8),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(tester.getBottomRight(markdown) - const Offset(2, 8));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(copied, contains('Lisbon'));
  });

  testWidgets('photo rails still drag-scroll with a mouse inside the wrap',
      (WidgetTester tester) async {
    const place = AgentPlace(
      name: 'Bar El Comercio',
      placeId: 'p1',
      address: 'Calle Lineros 9',
      lat: 37.39,
      lng: -5.99,
      rating: 4.5,
      priceLevel: 2,
      category: 'restaurant',
    );
    await _pumpSeededChat(
      tester,
      PlanState(
        messages: [
          PlanMessage(role: MessageRole.user, content: 'where should I eat?'),
        ],
        places: const [
          place, place, place, place, place, place, place, place, //
        ],
        placesQuery: 'tapas in seville',
      ),
    );
    await tester.pump();

    final rail = find.descendant(
      of: find.byType(PlacePhotoStrip),
      matching: find.byType(Scrollable),
    );
    expect(rail, findsOneWidget);
    final position = tester.state<ScrollableState>(rail).position;
    expect(position.pixels, 0);

    // A horizontal mouse drag over the rail must win the gesture arena
    // against the SelectionArea's selection drag.
    await tester.drag(rail, const Offset(-150, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump();

    expect(position.pixels, greaterThan(0));
  });
}
