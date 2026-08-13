import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/budget.dart';
import 'package:travel_route_planner/models/expense.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/budget_api_service.dart';
import 'package:travel_route_planner/providers/budget_provider.dart';
import 'package:travel_route_planner/utils/money_format.dart';
import 'package:travel_route_planner/widgets/budget_section.dart';

import 'support/l10n_test_app.dart';

/// A stateful fake: it holds the target/currency + the expense list so
/// invalidate-after-mutate reflects the change, derives spent/remaining exactly
/// like the server, and records which network methods were called.
class _FakeBudgetApiService extends BudgetApiService {
  final List<Expense> expenses;
  double? targetAmount;
  String currency;

  final List<Map<String, dynamic>> patches = [];
  final List<Map<String, dynamic>> puts = [];
  int addCount = 0;
  int deleteCount = 0;

  _FakeBudgetApiService(this.expenses, {this.targetAmount, this.currency = 'USD'})
      : super(ApiClient(baseUrl: 'http://test'));

  double get _spent => expenses.fold<double>(0, (s, e) => s + e.amount);

  @override
  Future<Budget> getBudget(String tripId) async => Budget(
        targetAmount: targetAmount,
        currency: currency,
        spent: _spent,
        remaining: targetAmount == null ? null : targetAmount! - _spent,
      );

  @override
  Future<List<Expense>> listExpenses(String tripId) async =>
      List.of(expenses); // snapshot

  @override
  Future<Budget> upsertBudget(String tripId,
      {double? targetAmount, String currency = 'USD'}) async {
    puts.add({'target_amount': targetAmount, 'currency': currency});
    this.targetAmount = targetAmount;
    this.currency = currency;
    return getBudget(tripId);
  }

  @override
  Future<Expense> addExpense(String tripId,
      {required String category,
      required String label,
      required double amount}) async {
    addCount++;
    final e = Expense(
        id: 'new-$addCount',
        category: category,
        label: label,
        amount: amount);
    expenses.add(e);
    return e;
  }

  @override
  Future<Expense> updateExpense(
      String tripId, String expenseId, Map<String, dynamic> body) async {
    patches.add({'id': expenseId, ...body});
    final idx = expenses.indexWhere((e) => e.id == expenseId);
    if (idx >= 0) {
      expenses[idx] = expenses[idx].copyWith(
        category: body['category'] as String?,
        label: body['label'] as String?,
        amount: (body['amount'] as num?)?.toDouble(),
      );
      return expenses[idx];
    }
    throw Exception('not found');
  }

  @override
  Future<void> deleteExpense(String tripId, String expenseId) async {
    deleteCount++;
    expenses.removeWhere((e) => e.id == expenseId);
  }
}

Expense _exp(String id, String category, String label, double amount) =>
    Expense(id: id, category: category, label: label, amount: amount);

Future<_FakeBudgetApiService> _pump(
  WidgetTester tester,
  List<Expense> expenses, {
  double? targetAmount,
  String currency = 'USD',
  bool canEdit = true,
  bool isOffline = false,
}) async {
  final fake = _FakeBudgetApiService(expenses,
      targetAmount: targetAmount, currency: currency);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        budgetApiServiceProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BudgetSection(
                tripId: 't1', canEdit: canEdit, isOffline: isOffline),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets(
      'renders expenses grouped with subtotals, a running total, and remaining',
      (tester) async {
    await _pump(
      tester,
      [
        _exp('a', 'flights', 'JFK→CDG', 400),
        _exp('b', 'food', 'Dinner', 60),
        _exp('c', 'food', 'Lunch', 40),
      ],
      targetAmount: 1000,
      currency: 'EUR',
    );

    // Headline shows spent / target with the progress bar underneath.
    expect(
        find.text('${formatMoney(500, 'EUR')} / ${formatMoney(1000, 'EUR')}'),
        findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 0.5);
    expect(find.text('50%'), findsOneWidget);
    // Category group headers.
    expect(find.text('Flights'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    // Flights subtotal = 400, Food subtotal = 100 (both in EUR).
    expect(find.text(formatMoney(400, 'EUR')), findsWidgets);
    expect(find.text(formatMoney(100, 'EUR')), findsOneWidget);
    // Running total = 500 spent.
    expect(find.text('Total spent'), findsOneWidget);
    expect(find.text(formatMoney(500, 'EUR')), findsWidgets);
    // Remaining = 1000 - 500 = 500.
    expect(find.text('Remaining'), findsOneWidget);
  });

  testWidgets('over target: bar caps at full and turns error-colored',
      (tester) async {
    await _pump(
      tester,
      [_exp('a', 'lodging', 'Hotel', 150)],
      targetAmount: 100,
    );

    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 1.0); // clamped — "over" signals through color
    final context = tester.element(find.byType(LinearProgressIndicator));
    expect(bar.color, Theme.of(context).colorScheme.error);
    expect(find.text('150%'), findsOneWidget);
  });

  testWidgets('no target: spend headline, no progress bar', (tester) async {
    await _pump(tester, [_exp('a', 'food', 'Lunch', 20)]);

    expect(find.textContaining('spent'), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('adding an expense posts to the service', (tester) async {
    final fake = await _pump(tester, [_exp('a', 'food', 'Lunch', 20)]);

    await tester.enterText(find.byType(TextField).first, 'Taxi');
    await tester.enterText(find.byType(TextField).last, '15');
    await tester.tap(find.byTooltip('Add expense'));
    await tester.pumpAndSettle();

    expect(fake.addCount, 1);
    expect(find.text('Taxi'), findsOneWidget);
  });

  testWidgets('editing an expense calls PATCH', (tester) async {
    final fake = await _pump(tester, [_exp('a', 'food', 'Lunch', 20)]);

    await tester.tap(find.byTooltip('Expense options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Lunch'), 'Brunch');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(fake.patches, isNotEmpty);
    expect(fake.patches.first['id'], 'a');
    expect(fake.patches.first['label'], 'Brunch');
  });

  testWidgets('setting a target calls PUT', (tester) async {
    final fake = await _pump(tester, [_exp('a', 'food', 'Lunch', 20)]);

    // The headline pencil opens the shared target dialog.
    await tester.tap(find.byTooltip('Set budget target'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Leave blank for none'), '800');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(fake.puts, isNotEmpty);
    expect(fake.puts.first['target_amount'], 800);
    expect(fake.puts.first['currency'], 'USD');
  });

  testWidgets('empty state shows the hint and an add field', (tester) async {
    await _pump(tester, []);

    expect(find.text('No budget yet'), findsOneWidget);
    expect(find.textContaining('track your spending'), findsOneWidget);
    // The add affordance is still available for the editor.
    expect(find.byTooltip('Add expense'), findsOneWidget);
  });

  testWidgets('viewer with no expenses and no target sees the read-only '
      'empty state (never a blank tab body)', (tester) async {
    await _pump(tester, [], canEdit: false);

    expect(find.text('No budget yet'), findsOneWidget);
    expect(find.byTooltip('Add expense'), findsNothing);
  });

  testWidgets('viewer sees amounts but no mutation affordances',
      (tester) async {
    await _pump(tester, [_exp('a', 'food', 'Lunch', 20)],
        targetAmount: 100, canEdit: false);

    // The section renders with its data (headline + row)...
    expect(
        find.text('${formatMoney(20, 'USD')} / ${formatMoney(100, 'USD')}'),
        findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
    // ...but no add row, per-expense menu, or target pencil.
    expect(find.byTooltip('Add expense'), findsNothing);
    expect(find.byTooltip('Expense options'), findsNothing);
    expect(find.byTooltip('Set budget target'), findsNothing);
  });

  testWidgets('offline disables the add affordance', (tester) async {
    await _pump(tester, [_exp('a', 'food', 'Lunch', 20)], isOffline: true);

    final addButton =
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add));
    expect(addButton.onPressed, isNull);
  });
}
