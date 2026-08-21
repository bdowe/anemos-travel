import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/fading_edge_scroll.dart';

// The contract worth pinning is not "there is a gradient" — it is WHICH edge
// fades and when. A fade means "there is more this way", so a constant one
// would promise more at exactly the moment there is none left.
//
// That rule is a pure function, tested here directly rather than by
// rasterizing the mask: `Picture.toImage` never completes under the headless
// test binding, and a pixel sample would pin the same arithmetic through a
// much more brittle lens. The widget tests below cover the wiring the pure
// function can't see — that the controller reaches the scroll view, and that
// the mask survives the fade engaging.

const double _viewport = 400;
const double _fade = 56; // 0.14 of the viewport

(double, double) _at(double pixels, {double maxExtent = 600}) =>
    fadingEdgeFractions(
      pixels: pixels,
      minExtent: 0,
      maxExtent: maxExtent,
      viewport: _viewport,
      fadeWidth: _fade,
    );

Future<ScrollController> _pump(WidgetTester tester,
    {int items = 8, double itemWidth = 120}) async {
  await tester.binding.setSurfaceSize(const Size(_viewport, 200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  late ScrollController controller;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 100,
        child: FadingEdgeScroll(
          fadeWidth: _fade,
          builder: (context, c) {
            controller = c;
            return ListView.builder(
              controller: c,
              scrollDirection: Axis.horizontal,
              itemCount: items,
              itemBuilder: (_, __) =>
                  Container(width: itemWidth, color: Colors.black),
            );
          },
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('which edge fades', () {
    test('at rest only the far edge fades', () {
      final (lead, trail) = _at(0);
      // Nothing has scrolled past the start, so dimming it would hide the
      // first card for no reason.
      expect(lead, 0);
      expect(trail, greaterThan(0));
    });

    test('mid-scroll both edges fade', () {
      final (lead, trail) = _at(300);
      expect(lead, greaterThan(0));
      expect(trail, greaterThan(0));
    });

    test('at the end the trailing fade stops promising more', () {
      final (lead, trail) = _at(600);
      expect(lead, greaterThan(0));
      // The regression a constant gradient would reintroduce: the last card
      // has to reach the edge at full ink.
      expect(trail, 0);
    });

    test('content that fits fades neither edge', () {
      // maxScrollExtent 0 — every card is already on screen.
      expect(_at(0, maxExtent: 0), (0.0, 0.0));
    });

    test('a rail resting a fraction off an end does not flicker its fade',
        () {
      expect(_at(0.4).$1, 0, reason: 'sub-pixel rest at the start');
      expect(_at(599.6).$2, 0, reason: 'sub-pixel rest at the end');
    });

    test('the two fades can never meet in the middle', () {
      final (lead, trail) = fadingEdgeFractions(
        pixels: 300,
        minExtent: 0,
        maxExtent: 600,
        viewport: 100,
        fadeWidth: 10000, // absurd on purpose
        );
      expect(lead, 0.4);
      expect(trail, 0.4);
      expect(lead + trail, lessThan(1));
    });

    test('a viewport with no width yields no fade', () {
      expect(
        fadingEdgeFractions(
            pixels: 0,
            minExtent: 0,
            maxExtent: 600,
            viewport: 0,
            fadeWidth: _fade),
        (0.0, 0.0),
      );
    });
  });

  testWidgets('the mask is present and the rail takes the controller',
      (tester) async {
    final c = await _pump(tester);

    expect(find.byType(ShaderMask), findsOneWidget);
    expect(c.hasClients, isTrue);
    expect(c.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('the scroll position survives the fade engaging', (tester) async {
    // The trap BookingFilterBar documents: swapping the mask in and out
    // re-parents the scroll view, rebuilding it and dropping the position.
    // The mask has to stay in the tree at every offset.
    final c = await _pump(tester);
    c.jumpTo(200);
    await tester.pumpAndSettle();
    expect(c.offset, 200);
    expect(find.byType(ShaderMask), findsOneWidget);

    c.jumpTo(c.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(c.offset, c.position.maxScrollExtent);
    expect(find.byType(ShaderMask), findsOneWidget);
  });

  testWidgets('a rail whose content fits still scrolls nothing and shows all',
      (tester) async {
    final c = await _pump(tester, items: 2, itemWidth: 100);
    expect(c.position.maxScrollExtent, 0);
    expect(find.byType(ShaderMask), findsOneWidget);
  });
}
