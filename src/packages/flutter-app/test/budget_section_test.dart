import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/budget.dart';
import 'package:travel_route_planner/models/expense.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/budget_api_service.dart';
import 'package:travel_route_planner/providers/budget_provider.dart';
import 'package:travel_route_planner/theme/app_theme.dart';
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
  final List<Map<String, dynamic>> adds = [];
  final List<Map<String, dynamic>> purchases = [];
  final List<String> unpurchases = [];
  int addCount = 0;
  int deleteCount = 0;

  /// Set to hold [addExpense] open, so a test can unmount the section while a
  /// save is still in flight.
  Completer<void>? addGate;

  _FakeBudgetApiService(this.expenses, {this.targetAmount, this.currency = 'USD'})
      : super(ApiClient(baseUrl: 'http://test'));

  // Mirrors the server's sumExpenses (budget_handler.go) off the raw columns,
  // not off the widget's helpers — that is the whole point of the fake.
  double get _spent =>
      expenses.fold<double>(0, (s, e) => s + (e.actualAmount ?? 0));
  double get _planned =>
      expenses.fold<double>(0, (s, e) => s + (e.plannedAmount ?? 0));
  double get _projected => expenses.fold<double>(
      0, (s, e) => s + (e.actualAmount ?? e.plannedAmount ?? 0));

  /// Scoped to lines carrying BOTH numbers; null when none do.
  double? get _variance {
    double sum = 0;
    var compared = false;
    for (final e in expenses) {
      if (e.actualAmount != null && e.plannedAmount != null) {
        sum += e.actualAmount! - e.plannedAmount!;
        compared = true;
      }
    }
    return compared ? sum : null;
  }

  @override
  Future<Budget> getBudget(String tripId) async => Budget(
        targetAmount: targetAmount,
        currency: currency,
        spent: _spent,
        remaining: targetAmount == null ? null : targetAmount! - _spent,
        planned: _planned,
        projected: _projected,
        planVariance: _variance,
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
      required double amount,
      bool planned = false,
      String? sourceKind,
      String? sourceId}) async {
    if (addGate != null) await addGate!.future;
    addCount++;
    adds.add({'label': label, 'category': category, 'amount': amount, 'planned': planned});
    final e = Expense(
        id: 'new-$addCount',
        category: category,
        label: label,
        amount: amount, // the derived column: one number either way
        plannedAmount: planned ? amount : null,
        actualAmount: planned ? null : amount,
        purchased: !planned,
        auto: sourceKind != null, // server rule mirrored
        sourceKind: sourceKind,
        sourceId: sourceId);
    expenses.add(e);
    return e;
  }

  /// The purchase verb pair (00067). `amount` omitted means "paid the planned
  /// amount"; the server 409s without a plan, which the widget never asks for.
  @override
  Future<Expense> purchaseExpense(String tripId, String expenseId,
      {double? amount}) async {
    purchases.add({'id': expenseId, 'amount': amount});
    return _replace(expenseId, (e) {
      final paid = amount ?? e.plannedAmount!;
      return e.copyWith(actualAmount: paid, purchased: true, amount: paid);
    });
  }

  @override
  Future<Expense> unpurchaseExpense(String tripId, String expenseId) async {
    unpurchases.add(expenseId);
    return _replace(expenseId, (e) {
      // Keeps the plan and restores it as the headline — the trigger's
      // COALESCE(actual, planned), mirrored.
      final plan = e.plannedAmount!;
      return e.copyWith(clearActual: true, purchased: false, amount: plan);
    });
  }

  Expense _replace(String expenseId, Expense Function(Expense) f) {
    final idx = expenses.indexWhere((e) => e.id == expenseId);
    if (idx < 0) throw Exception('not found');
    expenses[idx] = f(expenses[idx]);
    return expenses[idx];
  }

  @override
  Future<Expense> updateExpense(
      String tripId, String expenseId, Map<String, dynamic> body) async {
    patches.add({'id': expenseId, ...body});
    final idx = expenses.indexWhere((e) => e.id == expenseId);
    if (idx >= 0) {
      final before = expenses[idx];
      final plan = (body['planned_amount'] as num?)?.toDouble();
      // The legacy `amount` writes back to whichever column it was read from,
      // exactly as UpdateExpense resolves it in SQL.
      final legacy = (body['amount'] as num?)?.toDouble();
      final planned = plan ?? (legacy != null && !before.purchased ? legacy : null);
      final paid = legacy != null && before.purchased ? legacy : null;
      expenses[idx] = before.copyWith(
        category: body['category'] as String?,
        label: body['label'] as String?,
        plannedAmount: planned,
        actualAmount: paid,
        amount: paid ?? planned ?? before.amount,
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

/// A PAID line — what every expense was before the planned/paid split, so
/// every assertion written against these fixtures keeps its meaning.
Expense _exp(String id, String category, String label, double amount) =>
    Expense(
        id: id,
        category: category,
        label: label,
        amount: amount,
        actualAmount: amount,
        purchased: true);

/// A line that is only planned: no payment, so it counts toward `planned` and
/// `projected` but never toward `spent`.
Expense _planned(String id, String category, String label, double amount) =>
    Expense(
        id: id,
        category: category,
        label: label,
        amount: amount,
        plannedAmount: amount,
        purchased: false);

/// A line planned at one price and paid at another.
Expense _both(String id, String category, String label,
        {required double planned, required double paid}) =>
    Expense(
        id: id,
        category: category,
        label: label,
        amount: paid,
        plannedAmount: planned,
        actualAmount: paid,
        purchased: true);

Future<_FakeBudgetApiService> _pump(
  WidgetTester tester,
  List<Expense> expenses, {
  double? targetAmount,
  String currency = 'USD',
  bool canEdit = true,
  bool isOffline = false,
  Locale? locale,
}) async {
  final fake = _FakeBudgetApiService(expenses,
      targetAmount: targetAmount, currency: currency);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        budgetApiServiceProvider.overrideWithValue(fake),
      ],
      // The real app theme (filled + outline fields, Inter metrics) — an
      // unthemed harness is exactly how the truncated-hint bug escaped.
      child: MaterialApp(
      theme: AppTheme.light,
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('es')],
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

/// The Budget tab in miniature: a `BudgetSection` that comes and goes behind a
/// conditional, exactly as `trip_detail_screen`'s `if (_inBudgetView)` sliver
/// does. Everything a header-tab switch, a chat-panel toggle or an offline
/// banner does to that widget reduces to this.
class _Mountable extends StatefulWidget {
  final String tripId;
  const _Mountable({super.key, this.tripId = 't1'});

  @override
  State<_Mountable> createState() => _MountableState();
}

class _MountableState extends State<_Mountable> {
  bool _shown = true;
  late String _tripId = widget.tripId;

  /// Same element, different trip — drives `BudgetSection.didUpdateWidget`.
  void showTrip(String id) => setState(() => _tripId = id);

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(
          children: [
            TextButton(
              onPressed: () => setState(() => _shown = !_shown),
              child: const Text('toggle'),
            ),
            if (_shown)
              BudgetSection(tripId: _tripId, canEdit: true, isOffline: false),
          ],
        ),
      );
}

/// Pumps [_Mountable]s inside ONE `ProviderScope`. A second `pumpWidget` with
/// its own scope would build a fresh container and prove nothing about state
/// surviving — the container has to be the same one throughout.
Future<_FakeBudgetApiService> _pumpMountable(
  WidgetTester tester,
  List<Expense> expenses, {
  List<String> tripIds = const ['t1'],
  GlobalKey<_MountableState>? hostKey,
}) async {
  final fake = _FakeBudgetApiService(expenses);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [budgetApiServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: Column(
            children: [
              for (final id in tripIds)
                Expanded(
                  child: _Mountable(
                      key: id == tripIds.first ? hostKey : null, tripId: id),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

/// Toggles the [index]th section off and back on — one unmount/remount round
/// trip.
Future<void> _remount(WidgetTester tester, {int index = 0}) async {
  final toggle = find.text('toggle').at(index);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

TextEditingController _controllerAt(WidgetTester tester, int index) =>
    tester.widget<TextField>(find.byType(TextField).at(index)).controller!;

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
    final categoryButton = tester.widget<PopupMenuButton<String>>(find.ancestor(
        of: find.byTooltip('Category'),
        matching: find.byType(PopupMenuButton<String>)));
    expect(categoryButton.enabled, isFalse);
  });

  testWidgets(
      'amount hint renders un-truncated under the app theme at phone width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 690));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, [_exp('a', 'food', 'Lunch', 20)]);

    // A too-narrow hint ellipsizes (never throws), so "no exception" proves
    // nothing: the full string's intrinsic width must fit in the width the
    // field gave the hint. (Compared against constraints, not painted size —
    // painted width excludes trailing letter-spacing that intrinsic width
    // includes.) English only on purpose — the 1em-per-glyph FlutterTest
    // font inflates "Importe" past any realistic width, while Inter fits it
    // easily at the shipped 136px.
    final hint = find.text('Amount');
    expect(hint, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(hint);
    expect(
      paragraph.getMaxIntrinsicWidth(double.infinity),
      lessThanOrEqualTo(paragraph.constraints.maxWidth),
      reason: 'the Amount hint is being ellipsized — widen the amount field',
    );
  });

  testWidgets(
      'category menu opens with every label visible, checks the current '
      'category, and the selection flows into the add', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 690));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Empty list: category labels would otherwise collide with group headers.
    final fake = await _pump(tester, []);

    await tester.tap(find.byTooltip('Category'));
    await tester.pumpAndSettle();

    for (final label in [
      'Flights', 'Lodging', 'Food', 'Activities', //
      'Transport', 'Shopping', 'General',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // Current selection is checked (language_menu_button convention).
    expect(
      tester
          .widget<CheckedPopupMenuItem<String>>(find.widgetWithText(
              CheckedPopupMenuItem<String>, 'General'))
          .checked,
      isTrue,
    );

    // Tap the item, not its Text — CheckedPopupMenuItem wraps its ListTile
    // in an IgnorePointer (the item's own InkWell handles the tap), so the
    // Text itself never hit-tests.
    await tester
        .tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'Flights'));
    await tester.pumpAndSettle();
    // The trigger now shows the selected category's icon.
    expect(find.byIcon(Icons.flight_outlined), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'JFK→CDG');
    await tester.enterText(find.byType(TextField).last, '400');
    await tester.tap(find.byTooltip('Add expense'));
    await tester.pumpAndSettle();
    expect(fake.expenses.last.category, 'flights');
  });

  // Pricing a flight means leaving this tab — "Find flights" lives on the
  // booking rows, and asking the chat re-parents the whole trip body — so the
  // add row is unmounted mid-thought as a matter of course. What was typed
  // has to be there on the way back.
  testWidgets('a half-typed expense survives the section being unmounted',
      (tester) async {
    await _pumpMountable(tester, []);

    await tester.tap(find.byTooltip('Category'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'Flights'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'JFK→CDG');
    await tester.enterText(find.byType(TextField).last, '400');

    await _remount(tester);

    expect(_controllerAt(tester, 0).text, 'JFK→CDG');
    expect(_controllerAt(tester, 1).text, '400');
    // The category is part of the draft too — it was a choice, not a default.
    expect(find.byIcon(Icons.flight_outlined), findsOneWidget);
  });

  testWidgets('the restored text can be typed onto, not in front of',
      (tester) async {
    await _pumpMountable(tester, []);
    await tester.enterText(find.byType(TextField).first, 'Taxi');
    await tester.enterText(find.byType(TextField).last, '15');

    await _remount(tester);

    // Assigning `controller.text` would park the caret at -1 (normalized to
    // 0), so the next keystroke would land in FRONT of the restored value.
    expect(_controllerAt(tester, 0).selection.baseOffset, 'Taxi'.length);
    expect(_controllerAt(tester, 1).selection.baseOffset, '15'.length);
  });

  testWidgets('drafts do not leak between trips', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpMountable(tester, [], tripIds: const ['t1', 't2']);

    await tester.enterText(find.byType(TextField).at(0), 'Ferry to Naxos');
    await tester.enterText(find.byType(TextField).at(1), '38');
    await tester.pumpAndSettle();

    // The other trip's row is its own draft, not a shared one.
    expect(_controllerAt(tester, 2).text, isEmpty);
    expect(_controllerAt(tester, 3).text, isEmpty);
  });

  testWidgets('a saved expense leaves no draft behind', (tester) async {
    final fake = await _pumpMountable(tester, []);
    await tester.enterText(find.byType(TextField).first, 'Taxi');
    await tester.enterText(find.byType(TextField).last, '15');
    await tester.tap(find.byTooltip('Add expense'));
    await tester.pumpAndSettle();

    await _remount(tester);

    expect(_controllerAt(tester, 0).text, isEmpty);
    expect(_controllerAt(tester, 1).text, isEmpty);
    expect(fake.addCount, 1);
  });

  // The clear happens after the POST resolves, by which point the row may be
  // gone and its controllers disposed. If the draft were only cleared through
  // them, the just-saved expense would still be sitting in the row — one tap
  // from being added twice — and the refetch that makes it appear would have
  // been thrown away with them.
  testWidgets('…even when the section is unmounted mid-save', (tester) async {
    final fake = await _pumpMountable(tester, []);
    fake.addGate = Completer<void>();
    await tester.enterText(find.byType(TextField).first, 'Taxi');
    await tester.enterText(find.byType(TextField).last, '15');
    await tester.tap(find.byTooltip('Add expense'));
    await tester.pump();

    // Tab away while the save is still in flight.
    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();
    fake.addGate!.complete();
    await tester.pumpAndSettle();

    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();

    expect(_controllerAt(tester, 0).text, isEmpty);
    expect(_controllerAt(tester, 1).text, isEmpty);
    expect(fake.addCount, 1);
    // And the expense is actually on screen: the invalidation that refetches
    // it outlives the widget too.
    expect(find.text('Taxi'), findsOneWidget);
  });

  testWidgets('a trip swap on a reused element re-seeds from the new trip',
      (tester) async {
    final host = GlobalKey<_MountableState>();
    await _pumpMountable(tester, [], hostKey: host);
    await tester.enterText(find.byType(TextField).first, 'Flight to Amsterdam');

    host.currentState!.showTrip('t2');
    await tester.pumpAndSettle();
    expect(_controllerAt(tester, 0).text, isEmpty, reason: "t1's draft leaked");

    host.currentState!.showTrip('t1');
    await tester.pumpAndSettle();
    expect(_controllerAt(tester, 0).text, 'Flight to Amsterdam');
  });

  // The draft is written on every keystroke, so watching it from build() would
  // re-render the headline, every expense row and the totals per character.
  testWidgets('typing in the add row never rebuilds the expense list',
      (tester) async {
    await _pump(tester, [_exp('a', 'food', 'Lunch', 20)], targetAmount: 100);

    // _buildHeadline constructs a fresh LinearProgressIndicator every build,
    // so widget identity is a faithful "did build() re-run" sentinel.
    final before = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    await tester.enterText(find.byType(TextField).first, 'Taxi');
    await tester.pump();

    expect(
      identical(
        before,
        tester.widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator)),
      ),
      isTrue,
      reason: 'the draft is write-through only — ref.watch()ing it from '
          'build() re-renders every expense row on every keystroke',
    );
  });

  // --- planned vs paid (00067) -------------------------------------------
  //
  // The totals are the server's; what these assert is which of them reach the
  // screen, and how one line reads.

  group('planned vs paid', () {
    testWidgets('pre-trip: nothing is spent and the plan carries the summary',
        (tester) async {
      await _pump(tester, [
        _planned('a', 'flights', 'Flights', 1100),
        _planned('b', 'lodging', 'Hotel', 750),
        _planned('c', 'food', 'Dinners', 200),
      ], targetAmount: 2000);

      expect(find.text('\$0 / \$2,000'), findsOneWidget);
      // Two segments: money gone (none) behind money still committed.
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
      expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byKey(const ValueKey('budgetBarProjected')))
            .value,
        1.0,
        reason: 'the plan already fills the target',
      );
      expect(find.text('Projected \$2,050 · \$50 over target'), findsOneWidget);
      expect(find.text('Total planned'), findsOneWidget);
      // Nothing has been paid, so there is nothing to compare — and the row
      // says nothing rather than saying zero.
      expect(find.text('Vs plan'), findsNothing);
    });

    testWidgets('mid-trip: a pair row, the group marker, and the comparison',
        (tester) async {
      await _pump(tester, [
        _both('a', 'flights', 'JFK → CDG', planned: 1100, paid: 1150),
        _planned('b', 'food', 'Dinners', 200),
        _exp('c', 'food', 'Lunch at Nikkei', 34),
      ], targetAmount: 2000);

      // A line that came in at a different price shows both numbers; the two
      // settled ones show one.
      expect(find.text('\$1,100→\$1,150'), findsOneWidget);
      expect(find.text('\$200'), findsOneWidget);
      expect(find.text('\$34'), findsOneWidget);

      // The marker rides the group that still contains unpaid money, and only
      // that one.
      expect(find.byTooltip('Includes planned amounts'), findsOneWidget);

      expect(find.text('Total planned'), findsOneWidget);
      expect(find.text('Vs plan'), findsOneWidget);
      expect(find.text('\$50 over'), findsOneWidget);
    });

    testWidgets('end of trip: one bar, and the plan is still there to compare',
        (tester) async {
      await _pump(tester, [
        _both('a', 'flights', 'Flights', planned: 400, paid: 437),
        _both('b', 'lodging', 'Hotel', planned: 750, paid: 750),
        _both('c', 'food', 'Food', planned: 350, paid: 291),
      ], targetAmount: 2000);

      // Everything is bought, so there is no committed-but-unspent segment.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('Projected'), findsNothing);
      expect(find.byTooltip('Includes planned amounts'), findsNothing);
      // THE feature: the plan did not collapse to zero when the trip ended.
      expect(find.text('Total planned'), findsOneWidget);
      expect(find.text('\$1,500'), findsOneWidget);
      expect(find.text('\$1,478'), findsOneWidget);
      expect(find.text('\$22 under'), findsOneWidget);
    });

    testWidgets('a payload from before the split renders exactly as today',
        (tester) async {
      // An old server, or a bundle cached before 00067: no planned/projected,
      // rows carrying only `amount`.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            budgetApiServiceProvider.overrideWithValue(
                _LegacyBudgetApiService([
              const Expense(
                  id: 'a', category: 'food', label: 'Lunch', amount: 20),
            ])),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            localizationsDelegates: testLocalizationsDelegates,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: BudgetSection(
                    tripId: 't1', canEdit: true, isOffline: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('\$20 / \$100'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('Projected'), findsNothing);
      expect(find.text('Total planned'), findsNothing);
      expect(find.text('Vs plan'), findsNothing);
      // The line counted as spend before the split, so it still reads as paid.
      expect(find.byTooltip('Mark as planned'), findsOneWidget);
    });

    testWidgets('marking a line paid prefills the plan and posts the price',
        (tester) async {
      final fake = await _pump(
          tester, [_planned('a', 'lodging', 'Hotel Nacional', 750)],
          targetAmount: 2000);

      await tester.tap(find.byTooltip('Mark as paid'));
      await tester.pumpAndSettle();

      final field = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      expect(tester.widget<TextField>(field).controller!.text, '750',
          reason: 'paying exactly what you planned should be one tap');

      await tester.enterText(field, '812');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(fake.purchases, [
        {'id': 'a', 'amount': 812.0}
      ]);
      // The row now carries both numbers, and the totals follow.
      expect(find.text('\$750→\$812'), findsOneWidget);
      expect(find.text('\$62 over'), findsOneWidget);
    });

    testWidgets('un-paying keeps the plan and offers Undo', (tester) async {
      final fake = await _pump(
          tester, [_both('a', 'flights', 'Flights', planned: 400, paid: 372)],
          targetAmount: 2000);

      await tester.tap(find.byTooltip('Mark as planned'));
      await tester.pumpAndSettle();

      expect(fake.unpurchases, ['a']);
      expect(find.text('Flights moved back to planned'), findsOneWidget);
      // The plan survived: the line is offering to be paid again, and the
      // headline it shows is the plan rather than the payment it lost.
      expect(find.byTooltip('Mark as paid'), findsOneWidget);
      expect(find.text('\$372'), findsNothing);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(fake.purchases, [
        {'id': 'a', 'amount': 372.0}
      ]);
    });

    testWidgets('a line with no plan converts instead of failing',
        (tester) async {
      // The server cannot un-pay a line with no plan — it would be left with
      // no amount at all — so the client states the plan first.
      final fake = await _pump(tester, [_exp('a', 'food', 'Gelato', 6)],
          targetAmount: 2000);

      await tester.tap(find.byTooltip('Mark as planned'));
      await tester.pumpAndSettle();

      expect(fake.patches, [
        {'id': 'a', 'planned_amount': 6.0}
      ]);
      expect(fake.unpurchases, ['a']);
    });

    testWidgets('a booking-created line cannot be un-paid from here',
        (tester) async {
      final fake = await _pump(tester, [
        const Expense(
            id: 'a',
            category: 'lodging',
            label: 'Hotel',
            amount: 300,
            actualAmount: 300,
            purchased: true,
            auto: true,
            sourceKind: 'accommodation',
            sourceId: 'acc1'),
      ], targetAmount: 2000);

      // Its payment mirrors the booking, so it is un-paid by un-booking.
      expect(find.byTooltip('From a booking — un-book it to remove'),
          findsOneWidget);
      expect(find.byTooltip('Mark as planned'), findsNothing);

      // .first is the ROW's menu; the add row's category picker is also a
      // PopupMenuButton<String> and sits after it.
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      expect(find.text('Mark as planned'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
      expect(fake.unpurchases, isEmpty);
    });

    testWidgets('the add row defaults to planned and remembers the pick',
        (tester) async {
      final fake = await _pump(tester, [_exp('a', 'food', 'Lunch', 20)],
          targetAmount: 2000);

      await tester.enterText(find.byType(TextField).first, 'Museum pass');
      await tester.enterText(find.byType(TextField).last, '42');
      await tester.tap(find.byTooltip('Add expense'));
      await tester.pumpAndSettle();
      expect(fake.adds.single['planned'], isTrue,
          reason: 'a wrongly-planned row is visible; a wrongly-paid one is not');

      // Flip once, and it stays flipped for the rest of the session.
      await tester.tap(find.text('Paid'));
      await tester.pumpAndSettle();
      for (final label in ['Taxi', 'Coffee']) {
        await tester.enterText(find.byType(TextField).first, label);
        await tester.enterText(find.byType(TextField).last, '9');
        await tester.tap(find.byTooltip('Add expense'));
        await tester.pumpAndSettle();
      }
      expect(fake.adds.skip(1).every((a) => a['planned'] == false), isTrue);
    });

    testWidgets('offline cannot flip the mode or a line', (tester) async {
      final fake = await _pump(
          tester, [_planned('a', 'lodging', 'Hotel', 750)],
          targetAmount: 2000, isOffline: true);

      expect(
          tester
              .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
              .onSelectionChanged,
          isNull);
      await tester.tap(find.byTooltip('Mark as paid'));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(fake.purchases, isEmpty);
    });

    testWidgets('a viewer sees the state marks but cannot flip them',
        (tester) async {
      await _pump(tester, [
        _planned('a', 'lodging', 'Hotel', 750),
        _exp('b', 'food', 'Lunch', 20),
      ], targetAmount: 2000, canEdit: false);

      // Sharing a budget means sharing the whole story, read-only.
      expect(find.text('Total planned'), findsOneWidget);
      expect(find.byTooltip('Mark as paid'), findsNothing);
      expect(find.byTooltip('Mark as planned'), findsNothing);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
    });

    testWidgets('Spanish keeps Previsto for money and fits at 360px',
        (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await _pump(tester, [_planned('a', 'lodging', 'Hotel', 750)],
          targetAmount: 2000, locale: const Locale('es'));

      // "Planeado" is the trips-list travel-stats word for a whole trip; money
      // uses Previsto.
      expect(find.text('Previsto'), findsOneWidget);
      expect(find.text('Pagado'), findsOneWidget);
      expect(find.text('Total previsto'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// A server that predates the split: no `planned`/`projected` totals, and rows
/// carrying only the legacy `amount`.
class _LegacyBudgetApiService extends BudgetApiService {
  final List<Expense> expenses;
  _LegacyBudgetApiService(this.expenses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Budget> getBudget(String tripId) async => Budget(
        targetAmount: 100,
        currency: 'USD',
        spent: expenses.fold<double>(0, (s, e) => s + e.amount),
        remaining: 100 - expenses.fold<double>(0, (s, e) => s + e.amount),
      );

  @override
  Future<List<Expense>> listExpenses(String tripId) async => List.of(expenses);
}
