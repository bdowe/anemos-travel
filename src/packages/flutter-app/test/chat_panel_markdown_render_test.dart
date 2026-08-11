import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/unordered_ordered_list.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Chat markdown rendering contracts (perf-chat-render-bundle lane):
///
/// 1. Committed assistant messages render full markdown (bold, lists) via
///    GptMarkdown — with explicit component lists that EXCLUDE the LaTeX
///    components, so flutter_math_fork's KaTeX path (and its 16 shipped font
///    families, stripped by tool/strip_katex_fonts.dart) stays unreachable.
/// 2. The live streaming bubble renders plain Text: re-parsing the whole
///    growing string as markdown on every token flush is O(n²) over a reply.
///    Formatting appears when the message commits — accepted trade.

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

/// Collects every leaf text fragment rendered under [finder], with the
/// resolved style it carries.
List<(String, TextStyle?)> _textFragments(WidgetTester tester, Finder finder) {
  final fragments = <(String, TextStyle?)>[];
  void walk(InlineSpan span, TextStyle? inherited) {
    final style = span.style ?? inherited;
    if (span is TextSpan) {
      if (span.text != null) fragments.add((span.text!, style));
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    }
  }

  for (final rich in tester.widgetList<RichText>(
      find.descendant(of: finder, matching: find.byType(RichText)))) {
    walk(rich.text, null);
  }
  return fragments;
}

void main() {
  testWidgets('committed message renders bold and list as markdown',
      (WidgetTester tester) async {
    await _pumpSeededChat(
      tester,
      PlanState(messages: [
        PlanMessage(
          role: MessageRole.assistant,
          content: '**Lisbon** highlights:\n- Alfama\n- Belém Tower',
        ),
      ]),
    );

    final bubble = find.byType(ChatMessageBubble);
    expect(find.descendant(of: bubble, matching: find.byType(GptMarkdown)),
        findsOneWidget);

    final fragments = _textFragments(tester, bubble);
    final allText = fragments.map((f) => f.$1).join();
    // Bold parsed, not shown literally, and rendered with a bold weight.
    expect(allText, isNot(contains('**')));
    final lisbon = fragments.where((f) => f.$1.contains('Lisbon'));
    expect(lisbon, isNotEmpty);
    expect(lisbon.any((f) => f.$2?.fontWeight == FontWeight.bold), isTrue);
    // The two items render inside real unordered-list widgets (dash consumed).
    expect(find.descendant(of: bubble, matching: find.byType(UnorderedListView)),
        findsNWidgets(2));
    expect(allText, contains('Alfama'));
    expect(allText, contains('Belém Tower'));
  });

  testWidgets('LaTeX components are excluded: delimiters stay literal text',
      (WidgetTester tester) async {
    await _pumpSeededChat(
      tester,
      PlanState(messages: [
        PlanMessage(
          role: MessageRole.assistant,
          content: r'Distance: \(d = vt\) and \[E = mc^2\]',
        ),
      ]),
    );

    // With LatexMath/LatexMathMultiLine passed out of the component lists,
    // the delimiters survive as plain text instead of a flutter_math_fork
    // Math widget consuming them.
    final allText = _textFragments(tester, find.byType(ChatMessageBubble))
        .map((f) => f.$1)
        .join();
    expect(allText, contains(r'\(d = vt\)'));
    expect(allText, contains(r'\[E = mc^2\]'));
  });

  testWidgets('streaming bubble renders plain Text, not markdown',
      (WidgetTester tester) async {
    await _pumpSeededChat(
      tester,
      PlanState(
        messages: [PlanMessage(role: MessageRole.user, content: 'plan it')],
        isStreaming: true,
        streamingText: '**Lisbon** highlights:\n- Alfama',
      ),
    );

    // Two bubbles: the committed user message and the streaming tail. The
    // streaming one must not host a GptMarkdown — its raw markdown shows
    // verbatim until commit.
    expect(find.byType(ChatMessageBubble), findsNWidgets(2));
    expect(
        find.descendant(
            of: find.byType(ChatMessageBubble),
            matching: find.byType(GptMarkdown)),
        findsNothing);
    expect(find.text('**Lisbon** highlights:\n- Alfama'), findsOneWidget);
  });
}
