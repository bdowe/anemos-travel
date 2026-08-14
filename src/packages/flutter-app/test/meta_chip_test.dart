import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/widgets/meta_chip.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

// MetaChip carries card facts (date range, duration, city count, stays) inside
// a Wrap whose runs are only as wide as the card. A chip whose own natural
// width exceeds that run has nowhere to go — it must truncate its label, the
// same way StatusPill does, instead of striping the card with a RenderFlex
// overflow. The 192px constraint below is what a trips-list card's subtitle
// Wrap hands a chip at a 360px viewport.
const double _narrowRun = 192;

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _narrowRun,
            child: Wrap(children: [child]),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a long label truncates instead of overflowing the chip',
      (tester) async {
    await tester.pumpWidget(_host(
      // A month-crossing range at the widest month-name/day combination —
      // ~220px natural width against a 192px run.
      const MetaChip(label: 'Sep 23 – Oct 26', icon: Icons.event),
    ));
    await tester.pumpAndSettle();

    // Widget tests rethrow RenderFlex overflows at test end automatically —
    // reaching this line with a clean settle IS the assertion.
    expect(tester.takeException(), isNull);

    final text = tester.widget<Text>(find.text('Sep 23 – Oct 26'));
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.maxLines, 1);
  });

  testWidgets('a chip that fits is not shrunk or truncated', (tester) async {
    await tester.pumpWidget(_host(const MetaChip(label: '3 days')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The chip hugs its content (mainAxisSize.min), so a short label leaves
    // the pill narrower than the run it sits in.
    expect(tester.getSize(find.byType(MetaChip)).width, lessThan(_narrowRun));
  });

  testWidgets('MetaChip and StatusPill survive the same narrow run',
      (tester) async {
    // The two chips share a card's Wrap; a guard on only one of them still
    // stripes the card.
    await tester.pumpWidget(_host(
      const Column(
        children: [
          MetaChip(label: 'Sep 23 – Oct 26'),
          StatusPill.custom(
            label: 'Ahorra 320 € frente a la tarifa flexible',
            background: Colors.teal,
            foreground: Colors.white,
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
