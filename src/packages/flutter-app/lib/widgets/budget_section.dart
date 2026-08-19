import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/budget.dart';
import '../models/daily_spend.dart';
import '../models/expense.dart';
import '../providers/budget_provider.dart';
import '../theme/spacing.dart';
import '../utils/daily_spend.dart';
import '../utils/money_format.dart';
import '../utils/trip_legs.dart';
import 'budget_amounts.dart';
import 'budget_categories.dart';
import 'budget_target_dialog.dart';
import 'daily_spend_section.dart';
import 'empty_state.dart';
import 'trip_detail/budget_composer.dart';

/// The Budget tab's body: a single per-trip budget (one target in one
/// currency) with a spend headline + progress toward the target, a flat list
/// of expense line-items grouped by category with per-category subtotals, a
/// running total, and a remaining footer.
/// Self-contained — it owns its data via [budgetProvider] + [expensesProvider]
/// and reconciles mutations by invalidating both family keys. The add-expense
/// composer (add-options line + add row) lives in
/// `trip_detail/budget_composer.dart` — lifted out as a pure move; its unsaved
/// contents live in [expenseDraftProvider] rather than in either widget's
/// State, because the tab is unmounted every time the traveler changes header
/// tab or opens the chat panel. (The
/// `showHeader` knob died with the collapsed cluster row this tab replaced —
/// precedent: [TripReviewSection]'s knob retiring with the health sheet.)
class BudgetSection extends ConsumerStatefulWidget {
  final String tripId;
  final bool canEdit;
  final bool isOffline;

  /// The trip's city legs in itinerary order — the screen derivation's
  /// `legChips`, the same list the map strip renders. Required, not defaulted:
  /// an empty default would let the mount site silently lose the whole
  /// spend-per-city view. Keys are canonical `RenderLeg.Key` spellings
  /// (`Rome`, `Rome#2`); labels/qualifiers are display text.
  final List<({String key, String label, String? qualifier})> legChips;

  const BudgetSection({
    super.key,
    required this.tripId,
    required this.canEdit,
    required this.isOffline,
    required this.legChips,
  });

  @override
  ConsumerState<BudgetSection> createState() => _BudgetSectionState();
}

// Category vocabulary/labels/icons live in budget_categories.dart, shared
// with the booked-flip expense prompt; the planned-vs-paid row vocabulary
// lives in budget_amounts.dart.

/// What the edit dialog came back with. A record of the editable things,
/// so the caller can tell "left empty" (null) from "set to zero" — a plan of
/// zero is real data. [legKey] null means "no city" (00072); the caller
/// compares it against the expense to decide whether to PATCH at all.
class _ExpenseEdit {
  final String category;
  final String label;
  final double? planned;
  final double? paid;
  final String? legKey;

  const _ExpenseEdit({
    required this.category,
    required this.label,
    required this.planned,
    required this.paid,
    required this.legKey,
  });
}

class _BudgetSectionState extends ConsumerState<BudgetSection> {
  bool _busy = false;
  // The composer (BudgetComposer) owns the add row's controllers and its
  // draft write-back; this State only carries the shared busy flag its [_run]
  // wraps around every mutation.

  bool _guard() {
    if (widget.isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.commonOffline)),
      );
      return true;
    }
    return false;
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_guard() || _busy) return;
    // Captured while mounted. `ref` throws the moment this State is disposed
    // — and tabbing away mid-request is the routine case here, not the edge
    // one — which used to send both invalidations into the catch below: the
    // server had taken the write and no client ever refetched it.
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _busy = true);
    try {
      await op();
      container.invalidate(budgetProvider(widget.tripId));
      container.invalidate(expensesProvider(widget.tripId));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.commonGenericError)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _delete(Expense expense) => _run(() => ref
      .read(budgetApiServiceProvider)
      .deleteExpense(widget.tripId, expense.id));

  /// [_run] plus a confirmation snackbar carrying an Undo — for the one-tap
  /// actions, which are the ones worth mis-tapping. Delete deliberately keeps
  /// its no-undo behaviour: it asks nothing and takes a whole line, so it is
  /// already behind the overflow menu.
  Future<void> _runWithUndo(
    Future<void> Function() op, {
    required String message,
    required Future<void> Function() undo,
  }) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await _run(op);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      action: SnackBarAction(
        label: l10n.tripUndo,
        onPressed: () => _run(undo),
      ),
    ));
  }

  /// "I paid this." Prefilled with the plan, so paying exactly what you
  /// budgeted is Save — the common case — and a different price is one edit.
  Future<void> _markPaid(Expense expense, String currency) async {
    if (_guard()) return;
    final l10n = context.l10n;
    final planned = expense.plannedFor;
    final controller = TextEditingController(
        text: planned == null ? '' : _trimAmount(planned));
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.budgetPlanMarkPaid),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(expense.label, style: Theme.of(ctx).textTheme.bodySmall),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: l10n.budgetPlanPaidAmountLabel(currency),
                helperText: planned == null
                    ? null
                    : l10n.budgetPlanPlannedHelper(
                        formatMoney(planned, currency)),
              ),
              onSubmitted: (v) {
                final parsed = double.tryParse(v.trim());
                if (parsed != null && parsed >= 0) Navigator.of(ctx).pop(parsed);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              if (parsed == null || parsed < 0) return;
              Navigator.of(ctx).pop(parsed);
            },
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    if (amount == null) return;
    await _run(() => ref
        .read(budgetApiServiceProvider)
        .purchaseExpense(widget.tripId, expense.id, amount: amount));
  }

  /// "I haven't actually paid this." One tap, no dialog — the snackbar's Undo
  /// is the confirmation, matching the booked-flip pattern.
  ///
  /// A line with no plan can't be un-paid server-side (it would be left with no
  /// amount at all), so it is CONVERTED first: what was paid becomes the plan.
  /// Lossless and comprehensible — and it beats answering a mis-tap with a 409.
  Future<void> _unpay(Expense expense) async {
    final l10n = context.l10n;
    final api = ref.read(budgetApiServiceProvider);
    final paid = expense.paidAmount;
    final needsPlan = expense.plannedFor == null && paid != null;
    await _runWithUndo(
      () async {
        if (needsPlan) {
          await api.updateExpense(
              widget.tripId, expense.id, {'planned_amount': paid});
        }
        await api.unpurchaseExpense(widget.tripId, expense.id);
      },
      message: l10n.budgetPlanMovedBack(expense.label),
      undo: () =>
          api.purchaseExpense(widget.tripId, expense.id, amount: paid),
    );
  }

  /// Edit everything about a line: its category, its label, what it was
  /// planned at, and what it cost.
  ///
  /// The two amounts are stacked, not side by side — at 390px each would get
  /// ~127px and "Planned (USD)" / "Previsto (USD)" breaks under text scale.
  /// Emptying the Paid field un-pays the line; emptying Planned does NOT clear
  /// the plan, because nothing can (00067) — a plan, once stated, is history,
  /// and deleting the line is how you get rid of it.
  Future<void> _editExpense(Expense expense, String currency) async {
    if (_guard()) return;
    final l10n = context.l10n;
    final labelController = TextEditingController(text: expense.label);
    final plannedBefore = expense.plannedFor;
    final paidBefore = expense.paidAmount;
    final plannedController = TextEditingController(
        text: plannedBefore == null ? '' : _trimAmount(plannedBefore));
    final paidController = TextEditingController(
        text: paidBefore == null ? '' : _trimAmount(paidBefore));
    var category = normalizeExpenseCategory(expense.category);
    final cityOptions = _cityOptions;
    // Resolved against the CURRENT legs: a key the trip no longer renders
    // seeds as "No city" (and, unchanged, never posts).
    final legKeyBefore =
        cityOptions.any((c) => c.key == expense.legKey) ? expense.legKey : null;
    var legKey = legKeyBefore;
    var planCityLabel = expense.legKey ?? '';
    for (final c in cityOptions) {
      if (c.key == expense.legKey) planCityLabel = c.label;
    }
    final result = await showDialog<_ExpenseEdit>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l10n.budgetEditExpenseTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: InputDecoration(labelText: l10n.budgetCategoryLabel),
                onChanged: (v) => setLocal(() => category = v ?? 'general'),
                items: [
                  for (final cat in kExpenseCategories)
                    DropdownMenuItem(
                        value: cat, child: Text(expenseCategoryLabel(l10n, cat))),
                ],
              ),
              TextField(
                controller: labelController,
                autofocus: true,
                decoration: InputDecoration(labelText: l10n.budgetLabelField),
              ),
              if (cityOptions.isNotEmpty) ...[
                // Disabled-but-present on a plan row, not absent: "this line
                // is Rome's daily plan" is exactly what the traveler needs to
                // know when the control won't move (the server 409s the write
                // anyway — a plan slot's city is fixed, 00072).
                DropdownButtonFormField<String?>(
                  key: const Key('budget-edit-city'),
                  initialValue: legKey,
                  decoration:
                      InputDecoration(labelText: l10n.budgetCityLabel),
                  onChanged: expense.legPlan
                      ? null
                      : (v) => setLocal(() => legKey = v),
                  items: [
                    DropdownMenuItem<String?>(
                        value: null, child: Text(l10n.budgetCityNone)),
                    for (final c in cityOptions)
                      DropdownMenuItem<String?>(
                          value: c.key,
                          child: Text(c.qualifier == null
                              ? c.label
                              : '${c.label} · ${c.qualifier}')),
                  ],
                ),
                if (expense.legPlan) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    l10n.budgetCityPlanLocked(planCityLabel),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ],
              TextField(
                controller: plannedController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                    labelText: l10n.budgetPlanPlannedAmountLabel(currency)),
              ),
              TextField(
                controller: paidController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                    labelText: l10n.budgetPlanPaidAmountLabel(currency)),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(l10n.budgetPlanAmountsHelp,
                  style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l10n.commonCancel)),
            FilledButton(
              onPressed: () {
                final label = labelController.text.trim();
                final planned = double.tryParse(plannedController.text.trim());
                final paid = double.tryParse(paidController.text.trim());
                // At least one number, and no negatives — the same rule the
                // server enforces, so Save can't produce a 400.
                if (label.isEmpty ||
                    (planned == null && paid == null) ||
                    (planned != null && planned < 0) ||
                    (paid != null && paid < 0)) {
                  return;
                }
                Navigator.of(ctx).pop(_ExpenseEdit(
                    category: category,
                    label: label,
                    planned: planned,
                    paid: paid,
                    legKey: legKey));
              },
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;

    final api = ref.read(budgetApiServiceProvider);
    await _run(() async {
      // Content first, then the payment — the verbs own actual_amount and
      // PATCH owns everything else, so an edit that changes both is two calls
      // by construction, not by accident.
      final patch = <String, dynamic>{
        'category': result.category,
        'label': result.label,
        if (result.planned != null && result.planned != plannedBefore)
          'planned_amount': result.planned,
        // Only on change, and against the RESOLVED before-value, so opening
        // and saving an untouched dialog sends no leg_key at all. null →
        // the wire's ''-clears sentinel (see updateExpense's doc); a plan
        // row's dropdown is disabled, so this can never fire for one.
        if (result.legKey != legKeyBefore)
          'leg_key': result.legKey ?? '',
      };
      await api.updateExpense(widget.tripId, expense.id, patch);
      if (result.paid != paidBefore) {
        if (result.paid == null) {
          await api.unpurchaseExpense(widget.tripId, expense.id);
        } else {
          await api.purchaseExpense(widget.tripId, expense.id,
              amount: result.paid);
        }
      }
    });
  }

  Future<void> _editTarget(Budget budget) async {
    if (_guard()) return;
    // The shared dialog saves, invalidates both providers, and snacks on
    // failure itself (one dialog with the raise_budget health fix).
    await showBudgetTargetDialog(context, ref, widget.tripId, budget);
  }

  // Whole units for editing (prices are quoted that way); drop a trailing ".0".
  String _trimAmount(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final budgetAsync = ref.watch(budgetProvider(widget.tripId));
    final expensesAsync = ref.watch(expensesProvider(widget.tripId));
    // Best-effort: render nothing until both loads have data — the tab body
    // shouldn't shout an error or flash a spinner.
    final budget = budgetAsync.valueOrNull;
    final expenses = expensesAsync.valueOrNull;
    if (budget == null || expenses == null) return const SizedBox.shrink();

    final hasTarget = budget.targetAmount != null;
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final currency = budget.currency;

    // Viewers with nothing to show still get the (read-only) empty state —
    // the Budget tab keeps itself visible while open (anti-stranding), so
    // its body must never go blank.
    if (expenses.isEmpty && !hasTarget && !widget.canEdit) {
      return EmptyState(
        compact: true,
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.budgetEmptyTitle,
        message: l10n.budgetEmptyMessage,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (expenses.isEmpty && !hasTarget) ...[
          // Nothing tracked yet (editor): the target affordance + an invite;
          // the add row below is the other on-ramp.
          _buildTargetControl(theme, budget),
          EmptyState(
            compact: true,
            icon: Icons.account_balance_wallet_outlined,
            title: l10n.budgetEmptyTitle,
            message: l10n.budgetEmptyMessage,
          ),
        ] else ...[
          _buildHeadline(theme, budget),
          const SizedBox(height: AppSpacing.md),
          _buildReceipt(theme, budget, expenses, currency),
        ],
        if (widget.canEdit) ...[
          // The suggestion is an estimate fed to the receipt, so it takes a
          // recessed well — a deliberately quieter register than the raised
          // receipt card. Editors only — accepting one is a write.
          _buildSuggestionWell(
            theme,
            DailySpendSection(
              tripId: widget.tripId,
              expenses: expenses,
              isOffline: widget.isOffline,
              onAdd: _addDailySpend,
            ),
          ),
          BudgetComposer(
            tripId: widget.tripId,
            isOffline: widget.isOffline,
            cityOptions: _cityOptions,
            run: _run,
          ),
        ],
      ],
    );
  }

  /// Files a city's suggested food & drink as a PLANNED expense, stamped with
  /// the leg key so the suggestion card can find it again and a second tap
  /// returns the same line instead of a duplicate.
  ///
  /// Goes through [_run] like every other write here, so it shares the busy
  /// guard, the two invalidations and the error snackbar.
  Future<void> _addDailySpend(
      DailySpendCity city, double total, String label) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await _run(() => ref.read(budgetApiServiceProvider).addExpense(
          widget.tripId,
          category: kDailySpendCategory,
          label: label,
          amount: total,
          planned: true,
          legKey: city.legKey,
          // The flag, not the mere presence of legKey, is what makes this the
          // city's plan slot since 00072.
          legPlan: true,
        ));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.budgetDailyAdded(city.label))),
    );
  }

  /// The spend headline the collapsed cluster row used to carry, now the tab
  /// body's first line: "$120 / $2,000" when a target is set (with a
  /// progress bar underneath, error-colored once over), or
  /// "$120 spent · No target set" while tracking spend only. The pencil opens
  /// the shared target dialog and HUGS the headline — the row takes
  /// [MainAxisSize.min] so the edit affordance sits next to the only thing it
  /// can change, instead of floating at the far edge of the page.
  Widget _buildHeadline(ThemeData theme, Budget budget) {
    final l10n = context.l10n;
    final currency = budget.currency;
    final target = budget.targetAmount;
    final over = target != null && budget.spent > target;
    final headline = target != null
        ? '${formatMoney(budget.spent, currency)} / ${formatMoney(target, currency)}'
        : '${l10n.budgetSummarySpent(formatMoney(budget.spent, currency))}'
            ' · ${l10n.budgetSummaryNoTarget}';
    final pct = target != null && target > 0
        ? (budget.spent / target * 100).round()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                headline,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: over
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (widget.canEdit)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                color: theme.colorScheme.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                tooltip: l10n.budgetSetTargetTitle,
                onPressed: () => _editTarget(budget),
              ),
          ],
        ),
        if (pct != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(child: _buildBar(theme, budget, over, pct)),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '$pct%',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
        ..._buildProjectionLine(theme, budget),
      ],
    );
  }

  /// One bar, filled in two shades: solid is money gone, translucent is money
  /// still committed. The translucent segment is drawn only when there IS
  /// unspent plan, so a finished trip — and any payload from before the split
  /// — has exactly one bar, as it always did.
  Widget _buildBar(ThemeData theme, Budget budget, bool over, int pct) {
    final target = budget.targetAmount!;
    final projected = budget.projected;
    final spentValue = (budget.spent / target).clamp(0.0, 1.0).toDouble();
    // Two "over" states, and they are not the same claim: money you have
    // actually overspent is an error, money you merely plan to is a heads-up.
    final projectedOver = projected != null && projected > target;
    final showProjected = projected != null && projected > budget.spent;
    final bar = LinearProgressIndicator(
      key: const ValueKey('budgetBarSpent'),
      // Clamped: the bar caps at full; "over" signals through the error color
      // (bar + headline) and the negative Remaining line below.
      value: spentValue,
      minHeight: 6,
      // Transparent when the projected track is behind it, so the two segments
      // read as one bar rather than two stacked ones.
      backgroundColor: showProjected
          ? Colors.transparent
          : theme.colorScheme.surfaceContainerHighest,
      color: over ? theme.colorScheme.error : theme.colorScheme.primary,
      semanticsLabel: context.l10n.budgetTitle,
      semanticsValue: '$pct%',
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: showProjected
          ? Stack(children: [
              LinearProgressIndicator(
                key: const ValueKey('budgetBarProjected'),
                value: (projected / target).clamp(0.0, 1.0).toDouble(),
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: (projectedOver
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary)
                    .withValues(alpha: 0.35),
              ),
              bar,
            ])
          : bar,
    );
  }

  /// "Projected $2,134 · $134 over target" — where the trip lands if every
  /// unpaid line comes in at its plan. Absent when there is nothing left to
  /// spend, so it never restates the headline.
  List<Widget> _buildProjectionLine(ThemeData theme, Budget budget) {
    final projected = budget.projected;
    if (projected == null || projected <= budget.spent) return const [];
    final l10n = context.l10n;
    final target = budget.targetAmount;
    final currency = budget.currency;
    final overBy = target == null ? null : projected - target;
    final heading = overBy != null && overBy > 0;
    return [
      const SizedBox(height: AppSpacing.xs),
      Text(
        [
          l10n.budgetPlanProjected(formatMoney(projected, currency)),
          if (heading) l10n.budgetPlanOverTargetBy(formatMoney(overBy, currency)),
        ].join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(
          color: heading
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  Widget _buildTargetControl(ThemeData theme, Budget budget) {
    final hasTarget = budget.targetAmount != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: InkWell(
        onTap: () => _editTarget(budget),
        borderRadius: AppRadius.smAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.xs, horizontal: AppSpacing.xs),
          child: Row(
            // Hugs the content like the headline's pencil: the edit icon
            // belongs to the target line, not to the page's far edge.
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  hasTarget
                      ? context.l10n.budgetTargetSet(
                          formatMoney(budget.targetAmount!, budget.currency),
                          budget.currency)
                      : context.l10n.budgetNoTarget,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Icon(Icons.edit_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  /// The receipt as ONE raised surface: the card head carries the section
  /// title and — when the trip has city legs — the Group-by toggle that acts
  /// on the contents below it; the body is the category/city groups and the
  /// totals footer. Until this card the tab's numbers floated on the void.
  /// The card theme supplies the treatment (12px radius, elevation 3, tint
  /// off), so nothing here re-declares a surface.
  Widget _buildReceipt(
      ThemeData theme, Budget budget, List<Expense> expenses, String currency) {
    final l10n = context.l10n;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.budgetExpensesTitle,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (_cityOptions.isNotEmpty) _buildGroupControl(theme),
              ],
            ),
            ..._buildGroups(theme, expenses, currency),
            _buildTotals(theme, budget, expenses),
          ],
        ),
      ),
    );
  }

  /// The Group-by control, stripped of its own label — the receipt's card
  /// head now says what the segments act on, and dedicating a line to a
  /// two-segment pill spent vertical space the phone widths actually need.
  /// The Key and behaviour are unchanged; it is still shown to viewers
  /// because it is a way of reading the receipt, not a write.
  Widget _buildGroupControl(ThemeData theme) {
    return Consumer(builder: (context, ref, _) {
      final grouping = ref.watch(budgetGroupingProvider(widget.tripId));
      final l10n = context.l10n;
      return SegmentedButton<BudgetGrouping>(
        key: const Key('budget-group-by'),
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
        ),
        segments: [
          ButtonSegment(
            value: BudgetGrouping.category,
            label: Text(l10n.budgetGroupByCategory),
          ),
          ButtonSegment(
            value: BudgetGrouping.city,
            label: Text(l10n.budgetGroupByCity),
          ),
        ],
        selected: {grouping},
        onSelectionChanged: (picked) => ref
            .read(budgetGroupingProvider(widget.tripId).notifier)
            .state = picked.first,
      );
    });
  }

  /// The suggestion is a labelled model estimate fed INTO the receipt, so it
  /// takes a recessed well — the demoted register of the two surfaces on this
  /// tab (raised receipt, recessed suggestion). The section inside collapses
  /// to nothing for viewers, offline, or an empty guide, and the well must
  /// collapse with it: an empty tinted frame would be visual noise over the
  /// add row. Sizing the frame to the CHILD is what the wrapper's own padding
  /// can't express, so visibility is resolved from the providers here —
  /// the same watch the section itself performs, no second fetch.
  Widget _buildSuggestionWell(ThemeData theme, Widget child) {
    final settings = ref.watch(dailySpendSettingsProvider(widget.tripId));
    final guide = ref
        .watch(dailySpendProvider(
            DailySpendQuery(tripId: widget.tripId, tier: settings.tier)))
        .valueOrNull;
    if (widget.isOffline || guide == null || guide.isEmpty) return child;
    final fill = theme.colorScheme.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: AppRadius.mdAll,
        ),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: child,
      ),
    );
  }

  /// The pickable cities: the trip's legs minus the "Other places" run, which
  /// names no city. Filtered on the KEY, never the label — the label is
  /// localized, the key is canonical.
  List<({String key, String label, String? qualifier})> get _cityOptions => [
        for (final c in widget.legChips)
          if (c.key != kOtherPlacesLabel) c
      ];

  List<Widget> _buildGroups(
          ThemeData theme, List<Expense> expenses, String currency) =>
      ref.watch(budgetGroupingProvider(widget.tripId)) == BudgetGrouping.city
          ? _buildCityGroups(theme, expenses, currency)
          : _buildCategoryGroups(theme, expenses, currency);

  /// One group header: tinted icon tile + label + the hollow "still has
  /// planned money" mark + ONE subtotal — the projected one, which is the only
  /// subtotal that stays continuous across a trip (it equals the plan before
  /// departure and the spend after it). A second column here would turn the
  /// section into a spreadsheet; the hollow mark says "not all of this has
  /// left yet" without spending a word or a line. Shared by both groupings so
  /// their subtotals cannot diverge. The icon takes a tile now: the receipt
  /// card needs its group heads to READ as heads, and a bare 16px glyph at
  /// the same muted role as the label beside it could not lead its rows.
  Widget _buildGroupHeader(ThemeData theme,
      {required Key key,
      required IconData icon,
      required String label,
      required List<Expense> group,
      required String currency}) {
    final subtotal = groupProjectedSubtotal(group);
    final hasPlanned = groupHasPlanned(group);
    return Padding(
      key: key,
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(icon,
                size: 14, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (hasPlanned) ...[
            Tooltip(
              message: context.l10n.budgetPlanGroupHasPlanned,
              child: Icon(Icons.radio_button_unchecked,
                  size: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            formatMoney(subtotal, currency),
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCategoryGroups(
      ThemeData theme, List<Expense> expenses, String currency) {
    final byCategory = <String, List<Expense>>{};
    for (final e in expenses) {
      byCategory.putIfAbsent(normalizeExpenseCategory(e.category), () => []).add(e);
    }
    final widgets = <Widget>[];
    for (final cat in kExpenseCategories) {
      final group = byCategory[cat];
      if (group == null || group.isEmpty) continue;
      widgets.add(_buildGroupHeader(theme,
          key: Key('budget-group-$cat'),
          icon: kExpenseCategoryIcons[cat] ?? Icons.receipt_long_outlined,
          label: expenseCategoryLabel(context.l10n, cat),
          group: group,
          currency: currency));
      for (final e in group) {
        widgets.add(_buildRow(theme, e, currency));
      }
    }
    return widgets;
  }

  /// The spend-per-city view (00072): the same lines bucketed by
  /// [Expense.legKey], in the trip's own leg order, with everything unfiled —
  /// no key, or a key the trip no longer renders — under a trailing "Rest of
  /// trip". A line whose city is gone falls there rather than vanishing or
  /// minting a ghost header: 00070's snapshot promise, rendered. Rows keep a
  /// small category icon because the header no longer says what kind of spend
  /// a line is.
  List<Widget> _buildCityGroups(
      ThemeData theme, List<Expense> expenses, String currency) {
    final cities = _cityOptions;
    final known = {for (final c in cities) c.key};
    final byLeg = <String, List<Expense>>{};
    final rest = <Expense>[];
    for (final e in expenses) {
      final key = e.legKey;
      if (key != null && known.contains(key)) {
        byLeg.putIfAbsent(key, () => []).add(e);
      } else {
        rest.add(e);
      }
    }
    final widgets = <Widget>[];
    void emit(Key key, String label, List<Expense> group) {
      widgets.add(_buildGroupHeader(theme,
          key: key,
          icon: Icons.place_outlined,
          label: label,
          group: group,
          currency: currency));
      for (final e in group) {
        widgets.add(_buildRow(theme, e, currency, showCategoryIcon: true));
      }
    }

    for (final c in cities) {
      final group = byLeg[c.key];
      if (group == null || group.isEmpty) continue;
      final label =
          c.qualifier == null ? c.label : '${c.label} · ${c.qualifier}';
      emit(Key('budget-group-city-${c.key}'), label, group);
    }
    if (rest.isNotEmpty) {
      emit(const Key('budget-group-rest'), context.l10n.budgetGroupRestOfTrip,
          rest);
    }
    return widgets;
  }

  /// [showCategoryIcon] restores the category signal in the city grouping,
  /// where the header no longer carries it. Defaults false so the category
  /// view renders byte-identically to before the split.
  Widget _buildRow(ThemeData theme, Expense expense, String currency,
      {bool showCategoryIcon = false}) {
    final l10n = context.l10n;
    final paid = expenseIsPaid(expense);
    // A booking-created line is a mirror of its booking: its payment is the
    // system's, so it is un-paid by un-booking, not from here. Editing it is
    // still the documented takeover hatch (00061).
    final locked = expense.auto;
    final canFlip = widget.canEdit && !locked;
    return Padding(
      key: ValueKey(expense.id),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          // Replaces the dead indent this row used to carry: the state signal
          // and its tap target cost 12px net, not a new column.
          ExpenseStateGlyph(
            paid: paid,
            tooltip: locked ? l10n.budgetPlanAutoLocked : null,
            onTap: !canFlip
                ? null
                : () => paid ? _unpay(expense) : _markPaid(expense, currency),
          ),
          if (showCategoryIcon) ...[
            Icon(
                kExpenseCategoryIcons[
                        normalizeExpenseCategory(expense.category)] ??
                    Icons.receipt_long_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
          ],
          Expanded(
            child: Text(
              expense.label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
          ExpenseAmountCell(expense: expense, currency: currency),
          if (widget.canEdit)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
              tooltip: l10n.budgetExpenseOptions,
              onSelected: (v) {
                if (v == 'edit') _editExpense(expense, currency);
                if (v == 'delete') _delete(expense);
                if (v == 'paid') _markPaid(expense, currency);
                if (v == 'planned') _unpay(expense);
              },
              // The glyph is a 28px target, below the minimum tap size, so the
              // menu carries its accessible twin rather than being the only
              // way in.
              itemBuilder: (_) => [
                if (canFlip)
                  PopupMenuItem(
                    value: paid ? 'planned' : 'paid',
                    child: Text(paid
                        ? l10n.budgetPlanMarkPlanned
                        : l10n.budgetPlanMarkPaid),
                  ),
                PopupMenuItem(value: 'edit', child: Text(l10n.budgetMenuEdit)),
                PopupMenuItem(
                    value: 'delete', child: Text(l10n.commonDelete)),
              ],
            )
          else
            const SizedBox(width: AppSpacing.sm),
        ],
      ),
    );
  }

  /// The receipt's footer: what you planned (memo register — the visited
  /// totals are not the trip's bill) and what you spent (the ONE emphasized
  /// total, TripAdvisor's receipt discipline), then the plan comparison and
  /// what's left against the target as quiet lines. Every number is the
  /// server's — they are derived once, together, so no two lines here can
  /// disagree.
  Widget _buildTotals(ThemeData theme, Budget budget, List<Expense> expenses) {
    final currency = budget.currency;
    final l10n = context.l10n;
    final planned = budget.planned;
    final variance = budget.planVariance;
    final memoLabel = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final memoAmount = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Divider(height: 1),
        ),
        // Absent until something is actually planned, so a trip tracking spend
        // only reads exactly as it did before the split.
        if (planned != null && planned > 0) ...[
          Row(
            children: [
              Expanded(child: Text(l10n.budgetPlanTotalPlanned, style: memoLabel)),
              Text(formatMoney(planned, currency), style: memoAmount),
            ],
          ),
          const SizedBox(height: 2),
        ],
        Row(
          children: [
            Expanded(
              child: Text(l10n.budgetTotalSpent,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Text(
              formatMoney(budget.spent, currency),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        // Scoped by the server to lines carrying BOTH numbers: planned minus
        // spent mid-trip is "money not yet spent" plus variance, which is two
        // claims in one number. Null means nothing to compare yet — not zero.
        if (variance != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(l10n.budgetPlanVsPlan,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              Text(
                variance == 0
                    ? l10n.budgetPlanDeltaOnPlan
                    : variance > 0
                        ? l10n.budgetPlanDeltaOver(
                            formatMoney(variance, currency))
                        : l10n.budgetPlanDeltaUnder(
                            formatMoney(-variance, currency)),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: variance > 0
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
        if (budget.remaining != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(l10n.budgetRemaining,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              Text(
                formatMoney(budget.remaining!, currency),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: budget.remaining! < 0
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
