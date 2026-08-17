import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/dictation_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/dictation_controller.dart';
import 'package:travel_route_planner/services/dictation_engine.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// The composer is ONE line tall while empty, at every width and in every
/// shipped locale.
///
/// It was two on a phone: after the attach, mic and send buttons the field has
/// ~158px of text width, "Where do you want to go?" needs ~185, and
/// `InputDecoration` wraps a hint by default. Two independent guarantees now
/// hold it — a measured swap to a shorter hint (readable) and `hintMaxLines:
/// 1` (correct). Both are pinned here, because either alone leaves a hole:
/// without the measurement the hint is chopped, without the maxLines a locale
/// whose short hint is still too wide wraps the bar again.

/// Always initializes, so the mic button is deterministically PRESENT — the
/// narrow case. `_MicButton` collapses when dictation is unavailable, a 48px
/// swing in the field's width, which is exactly why the hint is measured
/// rather than switched on a window breakpoint.
class _FakeEngine implements DictationEngine {
  @override
  Future<bool> initialize() async => true;

  @override
  Stream<DictationEvent> start() => const Stream.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}

class _SeededPlanNotifier extends PlanNotifier {
  _SeededPlanNotifier(PlanState seeded)
      : super(PlanService('http://unused'), ApiClient()) {
    state = seeded;
  }
}

Future<void> _pumpComposer(
  WidgetTester tester, {
  required double width,
  Locale? locale,
  bool streaming = false,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final seeded = PlanState(
    messages: streaming
        ? [PlanMessage(role: MessageRole.user, content: 'plan athens')]
        : const [],
    isStreaming: streaming,
  );
  final provider = StateNotifierProvider<PlanNotifier, PlanState>(
      (ref) => _SeededPlanNotifier(seeded));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dictationControllerFactoryProvider.overrideWithValue(
          (textController) => DictationController(
            textController: textController,
            primary: _FakeEngine(),
            fallback: null,
            fallbackAvailable: () async => false,
          ),
        ),
      ],
      child: localizedTestApp(
        locale: locale,
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
  await tester.pump(); // engine init
}

/// One line of the composer field, generously: the field is ~48 tall with a
/// 10px vertical content padding, and a second line would add ~20.
const double _oneLineCeiling = 60;

void main() {
  testWidgets('a phone shows the short hint, on one line',
      (WidgetTester tester) async {
    await _pumpComposer(tester, width: 390);

    expect(find.text('Where to?'), findsOneWidget);
    expect(find.text('Where do you want to go?'), findsNothing);
    expect(tester.getSize(find.byType(TextField)).height,
        lessThan(_oneLineCeiling));
  });

  testWidgets('a wide window shows the full hint, still on one line',
      (WidgetTester tester) async {
    await _pumpComposer(tester, width: 900);

    expect(find.text('Where do you want to go?'), findsOneWidget);
    expect(find.text('Where to?'), findsNothing);
    expect(tester.getSize(find.byType(TextField)).height,
        lessThan(_oneLineCeiling));
  });

  testWidgets('Spanish fits on a phone too', (WidgetTester tester) async {
    await _pumpComposer(tester, width: 390, locale: const Locale('es'));

    // WHICH hint wins is deliberately not asserted here. Widget tests render
    // with the fixed-width test font, so a string's measured width is not the
    // width Inter gives it: in the real app "¿A dónde quieres ir?" fits at
    // 390px and the full hint is what shows (browser-verified), while under
    // the test font it does not and the short one wins. That divergence is
    // the measurement working — each locale gets the longest hint that fits —
    // so what this pins is the invariant that survives both fonts.
    final hint = tester
        .widget<TextField>(find.byType(TextField))
        .decoration!
        .hintText;
    expect(hint, anyOf('¿A dónde quieres ir?', '¿A dónde?'));
    expect(tester.getSize(find.byType(TextField)).height,
        lessThan(_oneLineCeiling));
  });

  testWidgets('the hint can never wrap, whatever it says',
      (WidgetTester tester) async {
    await _pumpComposer(tester, width: 390);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.hintMaxLines, 1,
        reason: 'the structural guarantee, independent of which hint won');
  });

  testWidgets('the mid-stream hint shortens on a phone as well',
      (WidgetTester tester) async {
    await _pumpComposer(tester, width: 390, streaming: true);

    expect(find.text('Follow-up…'), findsOneWidget);
    expect(find.text('Ask a follow-up…'), findsNothing);
    expect(tester.getSize(find.byType(TextField)).height,
        lessThan(_oneLineCeiling));
  });
}
