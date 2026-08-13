import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/hover_reveal.dart';

/// HoverReveal/HoverRevealed contract (the trip-detail scroll-slowdown bug):
///   * hidden controls keep their layout slot (opacity, never Visibility) so
///     trailing widths and drag geometry never shift and finders see them;
///   * hidden controls ignore pointers;
///   * the reveal is an INSTANT 0/1 opacity swap — never an animated fade.
///     A mid-fade fractional opacity forces a saveLayer per row per frame on
///     CanvasKit, and with a fade every row crossing under a parked cursor
///     during a scroll starts one; the overlapping fades made trip-detail
///     scrolling progressively slower the longer it went on;
///   * with no mouse connected (touch devices, widget tests) controls are
///     always revealed.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('hidden control keeps its layout slot and ignores taps',
      (tester) async {
    var pressed = 0;
    Widget button() => IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: () => pressed++,
        );

    await tester.pumpWidget(
        host(HoverRevealed(revealed: true, child: button())));
    final shownSize = tester.getSize(find.byType(IconButton));

    await tester.pumpWidget(
        host(HoverRevealed(revealed: false, child: button())));
    final hiddenSize = tester.getSize(find.byType(IconButton));

    // Same slot whether shown or hidden — layout must never shift on hover.
    expect(hiddenSize, shownSize);

    // Hidden ⇒ pointer-transparent: the tap lands on nothing.
    await tester.tap(find.byType(IconButton), warnIfMissed: false);
    expect(pressed, 0);
  });

  testWidgets('reveal is an instant 0/1 swap that schedules no animation',
      (tester) async {
    await tester.pumpWidget(host(
      SizedBox(
        width: 200,
        height: 48,
        child: HoverReveal(
          builder: (context, revealed) => HoverRevealed(
            revealed: revealed,
            // Plain child: no InkWell/Material so the only possible ticker
            // source would be a fade inside HoverRevealed itself.
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ));

    Opacity opacity() => tester.widget<Opacity>(find.descendant(
          of: find.byType(HoverRevealed),
          matching: find.byType(Opacity),
        ));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    // Mouse connected, pointer away from the region: hidden, exactly 0.
    expect(opacity().opacity, 0.0);

    // Enter: ONE frame later the control reads exactly 1.0 — no fade, no
    // implicit-animation ticker left running.
    await gesture.moveTo(tester.getCenter(find.byType(HoverReveal)));
    await tester.pump();
    expect(opacity().opacity, 1.0);
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'the reveal must not schedule any animation ticker');

    // Exit: instantly back to exactly 0.0, still no ticker.
    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(opacity().opacity, 0.0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('no mouse connected (touch) ⇒ always revealed', (tester) async {
    await tester.pumpWidget(host(
      HoverReveal(
        builder: (context, revealed) => HoverRevealed(
          revealed: revealed,
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    ));

    final opacity = tester.widget<Opacity>(find.descendant(
      of: find.byType(HoverRevealed),
      matching: find.byType(Opacity),
    ));
    expect(opacity.opacity, 1.0);
  });
}
