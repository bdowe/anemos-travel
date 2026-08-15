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
  int addCount = 0;
  int deleteCount = 0;

  /// Set to hold [addExpense] open, so a test can unmount the section while a
  /// save is still in flight.
  Completer<void>? addGate;

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
      required double amount,
      String? sourceKind,
      String? sourceId}) async {
    if (addGate != null) await addGate!.future;
    addCount++;
    final e = Expense(
        id: 'new-$addCount',
        category: category,
        label: label,
        amount: amount,
        auto: sourceKind != null, // server rule mirrored
        sourceKind: sourceKind,
        sourceId: sourceId);
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
      // The real app theme (filled + outline fields, Inter metrics) — an
      // unthemed harness is exactly how the truncated-hint bug escaped.
      child: MaterialApp(
      theme: AppTheme.light,
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
}
