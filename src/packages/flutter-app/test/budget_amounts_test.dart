import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/expense.dart';
import 'package:travel_route_planner/widgets/budget_amounts.dart';

import 'support/l10n_test_app.dart';

// budget_amounts_test.dart — the per-row half of planned-vs-paid (00067). The
// TOTALS are the server's (sumExpenses) and are asserted in Go; what is
// asserted here is how one line reads.

Expense _expense({
  double? planned,
  double? paid,
  String label = 'Flights',
}) {
  // `amount` mirrors what the server's derived column would hold, so the
  // fixtures can't drift from the wire.
  final amount = paid ?? planned ?? 0;
  return Expense(
    id: label,
    category: 'flights',
    label: label,
    amount: amount,
    plannedAmount: planned,
    actualAmount: paid,
    purchased: paid != null,
  );
}

void main() {
  group('expenseIsPaid', () {
    test('is the nullness of the paid amount, not a separate flag', () {
      expect(expenseIsPaid(_expense(planned: 400)), isFalse);
      expect(expenseIsPaid(_expense(paid: 372)), isTrue);
      expect(expenseIsPaid(_expense(planned: 400, paid: 372)), isTrue);
    });

    test('a payload that predates the split reads as paid', () {
      // An old server (or a response cached before 00067 shipped) sends only
      // `amount`, and that number always meant money spent.
      const legacy = Expense(
        id: 'legacy',
        category: 'general',
        label: 'Hotel',
        amount: 300,
      );
      expect(expenseIsPaid(legacy), isTrue);
      expect(legacy.paidAmount, 300);
      expect(legacy.plannedFor, isNull);
      expect(legacy.showsPair, isFalse);
    });

    test('planned zero is real data, not "never planned"', () {
      final free = _expense(planned: 0, label: 'Walking tour');
      expect(expenseIsPaid(free), isFalse);
      expect(free.plannedFor, 0);
      expect(expenseProjected(free), 0);
    });
  });

  group('group arithmetic', () {
    final group = [
      _expense(planned: 400, paid: 372),
      _expense(planned: 750, label: 'Hotel'),
      _expense(paid: 6, label: 'Gelato'),
    ];

    test('subtotal is the projected one: paid where known, planned otherwise', () {
      expect(groupProjectedSubtotal(group), 1128);
    });

    test('a group with unpaid money is marked, a settled one is not', () {
      expect(groupHasPlanned(group), isTrue);
      expect(groupHasPlanned([_expense(planned: 400, paid: 372)]), isFalse);
      expect(groupHasPlanned(const []), isFalse);
    });
  });

  group('ExpenseAmountCell', () {
    Future<void> pumpCell(WidgetTester tester, Expense e, {Locale? locale}) =>
        tester.pumpWidget(localizedTestApp(
          locale: locale,
          home: Scaffold(
            body: Row(children: [
              const Expanded(child: Text('label')),
              ExpenseAmountCell(expense: e, currency: 'USD'),
            ]),
          ),
        ));

    testWidgets('a planned-only line shows one number', (tester) async {
      await pumpCell(tester, _expense(planned: 400));
      expect(find.text('\$400'), findsOneWidget);
      expect(find.textContaining('→'), findsNothing);
    });

    testWidgets('equal amounts collapse — "\$750 → \$750" is noise',
        (tester) async {
      await pumpCell(tester, _expense(planned: 750, paid: 750));
      expect(find.text('\$750'), findsOneWidget);
      expect(find.textContaining('→'), findsNothing);
    });

    testWidgets('a line that came in at a different price shows the pair',
        (tester) async {
      await pumpCell(tester, _expense(planned: 1100, paid: 1150));
      final text = tester.widget<Text>(find.byType(Text).last);
      expect(text.textSpan!.toPlainText(), '\$1,100→\$1,150');
    });

    testWidgets('the pair is read out as two named numbers, not an arrow',
        (tester) async {
      await pumpCell(tester, _expense(planned: 1100, paid: 1150));
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Planned \$1,100, paid \$1,150'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('no overflow with a long label at text scale 1.5 on a phone',
        (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(localizedTestApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Row(children: [
              const Expanded(
                child: Text('Hotel Nacional de Cuba, four nights with breakfast'),
              ),
              ExpenseAmountCell(
                expense: _expense(planned: 12345, paid: 12900),
                currency: 'USD',
              ),
            ]),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('ExpenseStateGlyph', () {
    testWidgets('taps only when it is the traveler\'s to change',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(localizedTestApp(
        home: Scaffold(
          body: Column(children: [
            ExpenseStateGlyph(paid: false, onTap: () => taps++),
            const ExpenseStateGlyph(paid: true), // viewer / offline / auto row
          ]),
        ),
      ));
      expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      expect(taps, 1);
      await tester.tap(find.byIcon(Icons.check_circle));
      expect(taps, 1, reason: 'a non-interactive glyph must not fire');
    });

    testWidgets('Spanish keeps its own words for the two states',
        (tester) async {
      await tester.pumpWidget(localizedTestApp(
        locale: const Locale('es'),
        home: Scaffold(
          body: ExpenseStateGlyph(paid: false, onTap: () {}),
        ),
      ));
      expect(find.byTooltip('Marcar como pagado'), findsOneWidget);
    });
  });
}
