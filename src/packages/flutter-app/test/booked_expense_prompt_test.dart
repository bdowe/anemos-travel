import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/widgets/booked_expense_prompt.dart';

import 'support/l10n_test_app.dart';

void main() {
  group('deriveBookedExpensePrefill', () {
    test('a stay wins over its todo: lodging + the stay name', () {
      final p = deriveBookedExpensePrefill(
        todo: const BookingTodo(
            id: 't1', kind: 'stay', todoKey: 'k', title: 'Stay in Santorini'),
        stay: const Accommodation(id: 'a1', name: 'Cueva en Oia'),
      );
      expect(p.category, 'lodging');
      expect(p.label, 'Cueva en Oia');
    });

    test('a flight segment: flights + "origin → destination"', () {
      final p = deriveBookedExpensePrefill(
        segment: const TripSegment(
            id: 's1', mode: 'flight', origin: 'ATH', destination: 'JTR'),
      );
      expect(p.category, 'flights');
      expect(p.label, 'ATH → JTR');
    });

    test('a non-flight segment maps to transport', () {
      final p = deriveBookedExpensePrefill(
        segment: const TripSegment(
            id: 's1', mode: 'ferry', origin: 'Piraeus', destination: 'Naxos'),
      );
      expect(p.category, 'transport');
      expect(p.label, 'Piraeus → Naxos');
    });

    test('a routeless segment falls back to the todo title, then mode', () {
      expect(
        deriveBookedExpensePrefill(
          todo: const BookingTodo(
              id: 't1', kind: 'transport', todoKey: 'k', title: 'Ferry leg'),
          segment: const TripSegment(id: 's1', mode: 'ferry'),
        ).label,
        'Ferry leg',
      );
      expect(
        deriveBookedExpensePrefill(
                segment: const TripSegment(id: 's1', mode: 'train'))
            .label,
        'train',
      );
    });

    test('todo-only rows map by kind; transport rides todo.mode', () {
      expect(
        deriveBookedExpensePrefill(
                todo: const BookingTodo(
                    id: 't', kind: 'stay', todoKey: 'k', title: 'Hotel'))
            .category,
        'lodging',
      );
      // Transport todos default to flights (their search affordance), and
      // the per-leg mode menu refines them.
      expect(
        deriveBookedExpensePrefill(
                todo: const BookingTodo(
                    id: 't', kind: 'transport', todoKey: 'k', title: 'Fly'))
            .category,
        'flights',
      );
      expect(
        deriveBookedExpensePrefill(
                todo: const BookingTodo(
                    id: 't',
                    kind: 'transport',
                    todoKey: 'k',
                    title: 'Ferry',
                    mode: 'ferry'))
            .category,
        'transport',
      );
      expect(
        deriveBookedExpensePrefill(
                todo: const BookingTodo(
                    id: 't', kind: 'other', todoKey: 'k', title: 'Show'))
            .category,
        'general',
      );
    });
  });

  group('showBookedExpensePrompt', () {
    // Pumps the host app, opens the dialog, and returns the dialog's own
    // (still-pending) result future.
    Future<Future<BookedExpenseDraft?>> pumpPrompt(WidgetTester tester,
        {String currency = 'EUR',
        BookedExpensePrefill prefill = const BookedExpensePrefill(
            category: 'flights', label: 'ATH → JTR')}) async {
      late Future<BookedExpenseDraft?> result;
      await tester.pumpWidget(localizedTestApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () {
                result = showBookedExpensePrompt(context,
                    currency: currency, prefill: prefill);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('prefills category + label, labels the amount with the '
        'currency', (tester) async {
      await pumpPrompt(tester);

      expect(find.text('Add to budget?'), findsOneWidget);
      expect(find.text('Flights'), findsOneWidget); // pre-picked category
      expect(find.widgetWithText(TextField, 'ATH → JTR'), findsOneWidget);
      expect(find.text('Amount (EUR)'), findsOneWidget);
    });

    testWidgets('Skip pops null', (tester) async {
      final result = await pumpPrompt(tester);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });

    testWidgets('Save pops the edited draft', (tester) async {
      final result = await pumpPrompt(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'Amount (EUR)'), '240');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final draft = await result;
      expect(draft, isNotNull);
      expect(draft!.category, 'flights');
      expect(draft.label, 'ATH → JTR');
      expect(draft.amount, 240);
    });

    testWidgets('Save without a valid amount stays open', (tester) async {
      await pumpPrompt(tester);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Add to budget?'), findsOneWidget); // still open
    });
  });
}
