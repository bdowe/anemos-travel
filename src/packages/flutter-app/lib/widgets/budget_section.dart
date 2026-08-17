import 'dart:math' as math;

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
import 'budget_amounts.dart';
import 'budget_categories.dart';
import 'budget_target_dialog.dart';
import 'daily_spend_section.dart';
import 'empty_state.dart';

/// The Budget tab's body: a single per-trip budget (one target in one
/// currency) with a spend headline + progress toward the target, a flat list
/// of expense line-items grouped by category with per-category subtotals, a
/// running total, and a remaining footer.
/// Self-contained — it owns its data via [budgetProvider] + [expensesProvider]
/// and reconciles mutations by invalidating both family keys. The add row's
/// unsaved contents live in [expenseDraftProvider] rather than in this
/// widget's State, because the widget is unmounted every time the traveler
/// changes header tab or opens the chat panel. (The
/// `showHeader` knob died with the collapsed cluster row this tab replaced —
/// precedent: [TripReviewSection]'s knob retiring with the health sheet.)
class BudgetSection extends ConsumerStatefulWidget {
  final String tripId;
  final bool canEdit;
  final bool isOffline;

  const BudgetSection({
    super.key,
    required this.tripId,
    required this.canEdit,
    required this.isOffline,
  });

  @override
  ConsumerState<BudgetSection> createState() => _BudgetSectionState();
}

// Category vocabulary/labels/icons live in budget_categories.dart, shared
// with the booked-flip expense prompt; the planned-vs-paid row vocabulary
// lives in budget_amounts.dart.

/// What the edit dialog came back with. A record of the four editable things,
/// so the caller can tell "left empty" (null) from "set to zero" — a plan of
/// zero is real data.
class _ExpenseEdit {
  final String category;
  final String label;
  final double? planned;
  final double? paid;

  const _ExpenseEdit({
    required this.category,
    required this.label,
    required this.planned,
    required this.paid,
  });
}

class _BudgetSectionState extends ConsumerState<BudgetSection> {
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  bool _busy = false;
  // The picked category has no field here on purpose: it lives in the draft,
  // which is the one place any part of this row's unsaved contents lives.

  @override
  void initState() {
    super.initState();
    _seedFrom(widget.tripId);
  }

  @override
  void didUpdateWidget(BudgetSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Nothing to flush — every keystroke already wrote through — so a trip
    // swap on a reused element only has to re-seed. Unreachable from the one
    // mount site today, where the id is fixed for the screen's life; here so
    // that "which trip's draft is in these fields" is answered by the code
    // rather than by that convention.
    if (oldWidget.tripId != widget.tripId) _seedFrom(widget.tripId);
  }

  /// Loads [tripId]'s kept draft into the fields, then arms the write-back.
  /// Called from `initState`, never from `build`: seeding on rebuild would
  /// clobber the character just typed, and this way the early
  /// `SizedBox.shrink()` return cannot race it.
  ///
  /// `read`, never `watch` — watching the draft from `build` would re-render
  /// every expense row on every keystroke.
  void _seedFrom(String tripId) {
    final draft = ref.read(expenseDraftProvider(tripId));
    // Detached across the two assignments: [_saveDraft] writes both fields at
    // once, so a half-applied seed would post the outgoing trip's amount into
    // the incoming trip's draft before the next line corrected it. Removing a
    // listener that was never added is a no-op, so this is safe on first call.
    _labelController.removeListener(_saveDraft);
    _amountController.removeListener(_saveDraft);
    _labelController.value = _endCollapsed(draft.label);
    _amountController.value = _endCollapsed(draft.amountText);
    // Recorded on every change rather than on the way out: this row is
    // unmounted without warning (a header-tab switch, the chat panel
    // re-parenting the body), and by the time `dispose` runs the element is
    // already unmounted, so `ref` throws there.
    _labelController.addListener(_saveDraft);
    _amountController.addListener(_saveDraft);
  }

  /// Never assign `controller.text`: that setter parks the selection at
  /// offset -1, which the engine normalizes to 0, so the next keystroke lands
  /// in *front* of the restored value (the trap `airport_field.dart`
  /// documents).
  static TextEditingValue _endCollapsed(String text) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );

  void _saveDraft() =>
      ref.read(expenseDraftProvider(widget.tripId).notifier).setText(
            label: _labelController.text,
            amountText: _amountController.text,
          );

  @override
  void dispose() {
    _labelController.dispose();
    _amountController.dispose();
    super.dispose();
  }

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

  void _add() {
    final label = _labelController.text.trim();
    final amount = double.tryParse(_amountController.text.trim());
    if (label.isEmpty || amount == null || amount < 0) return;
    final key = expenseDraftProvider(widget.tripId);
    final draftNow = ref.read(key);
    final category = draftNow.category;
    final planned = draftNow.planned;
    // Captured before the await: this row can be unmounted mid-save (tab away
    // while the POST is in flight), and by the time it returns the controllers
    // are disposed and `ref` throws. The draft outlives both, so clearing it
    // has to go through the notifier — otherwise the expense just saved sits
    // in the row waiting to be added a second time.
    final draft = ref.read(key.notifier);
    _run(() async {
      await ref.read(budgetApiServiceProvider).addExpense(
            widget.tripId,
            category: category,
            label: label,
            amount: amount,
            planned: planned,
          );
      if (mounted) {
        _labelController.clear();
        _amountController.clear();
      }
      draft.clearText();
    });
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
                    paid: paid));
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
          ..._buildGroups(theme, expenses, currency),
          _buildTotals(theme, budget, expenses),
        ],
        if (widget.canEdit) ...[
          // Suggestions sit between the receipt and the add row: an input to
          // planning, next to the other way of adding a line, and never above
          // the real numbers. Editors only — accepting one is a write.
          DailySpendSection(
            tripId: widget.tripId,
            expenses: expenses,
            isOffline: widget.isOffline,
            onAdd: _addDailySpend,
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildModeControl(theme),
          _buildAddRow(theme),
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
        ));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.budgetDailyAdded(city.label))),
    );
  }

  /// The spend headline the collapsed cluster row used to carry, now the tab
  /// body's first line: "$120 / $2,000" when a target is set (with a
  /// progress bar underneath, error-colored once over), or
  /// "$120 spent · No target set" while tracking spend only. The pencil
  /// opens the shared target dialog.
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
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
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
      ),
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
            children: [
              Icon(Icons.flag_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
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

  List<Widget> _buildGroups(
      ThemeData theme, List<Expense> expenses, String currency) {
    final byCategory = <String, List<Expense>>{};
    for (final e in expenses) {
      byCategory.putIfAbsent(normalizeExpenseCategory(e.category), () => []).add(e);
    }
    final widgets = <Widget>[];
    for (final cat in kExpenseCategories) {
      final group = byCategory[cat];
      if (group == null || group.isEmpty) continue;
      // ONE number per group — the projected one, which is the only subtotal
      // that stays continuous across a trip (it equals the plan before
      // departure and the spend after it). A second column here would turn
      // the section into a spreadsheet; the hollow mark says "not all of this
      // has left yet" without spending a word or a line.
      final subtotal = groupProjectedSubtotal(group);
      final hasPlanned = groupHasPlanned(group);
      widgets.add(Padding(
        padding:
            const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
        child: Row(
          children: [
            Icon(kExpenseCategoryIcons[cat],
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                expenseCategoryLabel(context.l10n, cat),
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
      ));
      for (final e in group) {
        widgets.add(_buildRow(theme, e, currency));
      }
    }
    return widgets;
  }

  Widget _buildRow(ThemeData theme, Expense expense, String currency) {
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

  /// The receipt: what you planned, what you spent, how the two compare, and
  /// what's left against the target. Every number is the server's — they are
  /// derived once, together, so no two lines here can disagree.
  Widget _buildTotals(ThemeData theme, Budget budget, List<Expense> expenses) {
    final currency = budget.currency;
    final l10n = context.l10n;
    final planned = budget.planned;
    final variance = budget.planVariance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Divider(height: 1),
        ),
        // Absent until something is actually planned, so a trip tracking spend
        // only reads exactly as it did before the split.
        if (planned != null && planned > 0) ...[
          Row(
            children: [
              Expanded(
                child: Text(l10n.budgetPlanTotalPlanned,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Text(
                formatMoney(planned, currency),
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 2),
        ],
        Row(
          children: [
            Expanded(
              child: Text(l10n.budgetTotalSpent,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            Text(
              formatMoney(budget.spent, currency),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
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

  /// Planned or paid, for whatever the add row is about to save.
  ///
  /// On its OWN LINE rather than inside the add row: that row already spends
  /// 240px of its 358 on fixed-width controls, and the "Add an expense…" hint
  /// barely fits in what's left — any horizontal addition kills it. Vertical
  /// space in a scrolling tab body is nearly free; horizontal space is the
  /// scarce resource.
  ///
  /// "Barely fits" turned out to be "doesn't": the hint was truncating to
  /// "Add a…" on every phone, and [_buildAddRow] now stacks onto two lines
  /// when it can't seat both fields. That vindicates this control's own line
  /// rather than reversing it — putting it back in the row would only make the
  /// row stack at wider and wider windows.
  ///
  /// The pick is read from the draft, so it survives the remount that changing
  /// header tab or opening the chat panel causes — a choice, like the category
  /// beside it.
  Widget _buildModeControl(ThemeData theme) {
    return Consumer(builder: (context, ref, _) {
      final planned = ref
          .watch(expenseDraftProvider(widget.tripId).select((d) => d.planned));
      final l10n = context.l10n;
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
            ),
            segments: [
              ButtonSegment(
                value: true,
                label: Text(l10n.budgetPlanStatePlanned),
              ),
              ButtonSegment(
                value: false,
                label: Text(l10n.budgetPlanStatePaid),
              ),
            ],
            selected: {planned},
            onSelectionChanged: widget.isOffline
                ? null
                : (picked) => ref
                    .read(expenseDraftProvider(widget.tripId).notifier)
                    .setPlanned(picked.first),
          ),
        ),
      );
    });
  }

  /// What a dense outline field spends on chrome either side of its text.
  /// Flutter 3.35's `InputDecorator` gives the M3 + dense + outline branch a
  /// `contentPadding` of 12 per side (input_decorator.dart:2600-2603) and then
  /// deducts `OutlineInputBorder.gapPadding` (4 — input_border.dart:332) per
  /// side as well (:2609-2613, :992-1008), so the hint is laid out at exactly
  /// `fieldWidth - _fieldChrome`. That is the width the regression tests read
  /// straight off `RenderParagraph.constraints`. (The old note here said "16px
  /// per side" — right in total, wrong about where it comes from.)
  static const double _fieldChrome = 32;

  /// A hint whose intrinsic width lands EXACTLY on the interior is one
  /// sub-pixel from ellipsizing itself, and a fractional device pixel ratio is
  /// enough to get there. One spacing step of headroom is plenty, because the
  /// measurement below already uses the same painter inputs the hint's own
  /// paragraph does — this covers rounding, not disagreement.
  static const double _hintFitSlack = AppSpacing.xs;

  /// Width of each of the row's two icon affordances.
  ///
  /// **Declared, not predicted** — the row renders both inside a `SizedBox` of
  /// this width, so the number the arithmetic spends is the number the row
  /// occupies. That is the whole difference between this constant and the 136
  /// it replaces, and predicting would have been wrong anyway: `IconButton`
  /// takes its tap-target size from the platform, so the add button is 48 on
  /// Android/iOS and silently **40** on macOS/Linux/Windows
  /// (theme_data.dart:398-408). Pinning it makes the row platform-invariant
  /// and brings the desktop tap target back up to Material's minimum.
  ///
  /// Legitimately a constant even in a file about measuring: 48 encodes a
  /// touch-target spec, not a string, so it doesn't move with locale — and it
  /// can't move with text scale either, since `Icon.applyTextScaling` defaults
  /// to false and nothing here enables it.
  static const double _controlWidth = kMinTouchTarget;

  /// Everything on the add row that is not a field: the two icon affordances
  /// and the two gaps. None of it is text, so none of it moves with the text
  /// scaler; the terms that DO move are the hints, and those are measured.
  static const double _addRowFixedWidth =
      2 * _controlWidth + 2 * AppSpacing.sm;

  /// The amount field has two things to seat and its hint is the smaller one,
  /// so the figure is named here instead of folded into a magic width: a
  /// five-figure amount with cents — a flight or a hotel total, the widest
  /// thing that lands on one expense line. Sizing the box from
  /// "Amount"/"Importe" alone would give ~82px, which reads fine and is
  /// miserable to type in.
  ///
  /// Only characters this field's own [FilteringTextInputFormatter] admits: a
  /// sample containing a thousands separator would size the box for text it
  /// can never hold.
  static const String _amountWidthSample = '88888.88';

  /// The width a field needs for [text] to render in full, chrome included —
  /// directly comparable to the width a `SizedBox`/`Expanded` hands the field.
  ///
  /// Measured, not assumed: the strings are translated ("Añade un gasto…"),
  /// the text scaler is the traveler's, and the 1em-per-glyph FlutterTest font
  /// moves both again. A constant can only ever be right for the one string
  /// somebody measured — which is exactly how the description hint shipped
  /// truncated to "Add a…" while the amount hint had a regression test.
  ///
  /// The style is the one `InputDecorator` actually paints a hint with:
  /// `textTheme.bodyLarge` merged with the M3 default hint style, which sets
  /// only a colour (input_decorator.dart:2170-2183, :5897-5902). These fields
  /// pass neither `style` nor `hintStyle`, so nothing else contributes.
  /// `Text` merges `MediaQuery.boldTextOf` on top of that, so this does too.
  ///
  /// `maxIntrinsicWidth`, not `width`: painted width omits the trailing
  /// letter-spacing the field's constraint still has to cover, and intrinsic
  /// width is the quantity the tests compare against `constraints.maxWidth` —
  /// the widget's arithmetic and the tests' oracle have to be the same number.
  ///
  /// Same shape as the overview show-more toggle's `_collapsedClips`
  /// (trip_detail_screen.dart): synchronous, one layout pass, no post-frame
  /// re-measure.
  static double _fieldWidthFor(BuildContext context, String text) {
    var style = Theme.of(context).textTheme.bodyLarge;
    if (MediaQuery.boldTextOf(context)) {
      style = style?.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final width = painter.maxIntrinsicWidth;
    painter.dispose();
    return (width + _fieldChrome + _hintFitSlack).ceilToDouble();
  }

  /// Closed state stays icon-compact (the add row is width-tight on phones);
  /// the open menu spells out each category. A popup menu (not a
  /// DropdownButton) because a dropdown's menu is hard-constrained to the
  /// trigger's width — an icon-only trigger would clip every label.
  ///
  /// The pick is read straight from the draft rather than mirrored into a
  /// field, so there is one answer to "which category is armed". The watch is
  /// scoped to this button and selects one String, so typing in the fields
  /// beside it can never re-render the expense list — or re-run the
  /// measurement beside it.
  Widget _buildCategoryTrigger(ThemeData theme) {
    return Consumer(builder: (context, ref, _) {
      final category = ref
          .watch(expenseDraftProvider(widget.tripId).select((d) => d.category));
      return SizedBox(
        width: _controlWidth,
        child: PopupMenuButton<String>(
          // Zero, not the default all(8) that PopupMenuButton forwards to its
          // IconButton: the two 18px icons plus 8+8 measure 52, which would
          // overflow the 48 the row's arithmetic spends here. 36 centred in 48
          // leaves 6 a side and reads the same.
          padding: EdgeInsets.zero,
          tooltip: context.l10n.budgetCategoryLabel,
          enabled: !widget.isOffline,
          icon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(kExpenseCategoryIcons[category],
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
              Icon(Icons.arrow_drop_down,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
          onSelected: (v) => ref
              .read(expenseDraftProvider(widget.tripId).notifier)
              .setCategory(v),
          itemBuilder: (_) => [
            for (final cat in kExpenseCategories)
              CheckedPopupMenuItem<String>(
                value: cat,
                checked: cat == category,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(kExpenseCategoryIcons[cat],
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpacing.sm),
                    Text(expenseCategoryLabel(context.l10n, cat)),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }

  /// Neither field passes a `style:`, and the theme passes no `hintStyle:`, on
  /// purpose: that is what makes the hint's metrics exactly `bodyLarge`, which
  /// is what [_fieldWidthFor] measures. Adding either without teaching the
  /// measurement about it silently un-derives the row.
  Widget _buildLabelField() => TextField(
        controller: _labelController,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.budgetAddHint,
        ),
      );

  Widget _buildAmountField() => TextField(
        controller: _amountController,
        textInputAction: TextInputAction.done,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.budgetAmount,
        ),
        onSubmitted: (_) => _add(),
      );

  /// Pick a category, say what it was, say what it cost, commit.
  ///
  /// One line while both fields can have the width their hints need, two lines
  /// below that. Measured rather than thresholded, because what runs out is a
  /// translated string at the traveler's text scale and no px breakpoint is
  /// right for every combination of those: at 390px the description field got
  /// ~106px and its hint truncated to "Add a…" — illegible, and too narrow to
  /// type into either, so shortening the copy would only have made an unusable
  /// field readable.
  ///
  /// It truncated rather than wrapped because a field hint inherits
  /// `hintMaxLines` from `TextField.maxLines`, which is 1, and a hint with a
  /// max-lines gets `TextOverflow.ellipsis` against a tight layout width. So
  /// the failure was silent by construction: no overflow stripes, no thrown
  /// exception, just a shorter string. Only a width assertion catches it,
  /// which is why the tests measure rather than watch for exceptions.
  ///
  /// Stacked, the money and the commit drop to a second line and the
  /// description takes the width back, while the category trigger stays glued
  /// to the field it categorizes — where it reads as that field's leading
  /// icon, which is what it is.
  ///
  /// The decision can't oscillate: this row's width comes from the sliver
  /// above it, never from its own children, so stacking cannot change the
  /// constraint that caused it.
  Widget _buildAddRow(ThemeData theme) {
    // LayoutBuilder, never MediaQuery (house rule, chat_panel.dart): the width
    // this row gets is the trip BODY's, and a docked chat panel takes 401px of
    // it without the window changing at all.
    return LayoutBuilder(builder: (context, constraints) {
      final labelWidth = _fieldWidthFor(context, context.l10n.budgetAddHint);
      final amountWidth = math.max(
        _fieldWidthFor(context, context.l10n.budgetAmount),
        _fieldWidthFor(context, _amountWidthSample),
      );
      final category = _buildCategoryTrigger(theme);
      final label = _buildLabelField();
      final amount = _buildAmountField();
      // Declared to _controlWidth for the same reason as the category trigger
      // — and it is a fix as well as a declaration: on desktop this button was
      // 40 wide, under Material's 48 minimum.
      final add = SizedBox(
        width: _controlWidth,
        child: IconButton(
          icon: const Icon(Icons.add),
          tooltip: context.l10n.budgetAddExpenseTooltip,
          onPressed: widget.isOffline ? null : _add,
        ),
      );

      // A ladder, cheapest concession first — the description keeps whatever
      // company it can while still showing its hint whole:
      //
      //   1. everything on one line
      //   2. the money and the commit drop to a second line
      //   3. the category drops too, and the description takes the whole line
      //
      // Unbounded width takes rung 1: it seats anything, and the Expanded
      // would already have thrown there, so the guard only feeds the
      // arithmetic.
      if (!constraints.maxWidth.isFinite ||
          constraints.maxWidth >=
              _addRowFixedWidth + labelWidth + amountWidth) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            category,
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: label),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(width: amountWidth, child: amount),
            add,
          ],
        );
      }

      // Rung 3 is the accessibility rung, not a phone rung: a 320px body at a
      // large text scale is where the category trigger's 48 + 8 stops being
      // affordable. Below THIS nothing helps and the hint ellipsizes as it
      // always did — but by then the description has the widest line the row
      // can offer, which is the most the layout can honestly do.
      final categorySharesTheLabelsLine =
          constraints.maxWidth - _controlWidth - AppSpacing.sm >= labelWidth;

      // Both fields keep their order and their relative position on every
      // rung, so reading-order traversal carries `next` from the label to the
      // amount and `done` to _add() — except on rung 3, where the category
      // trigger now sits between them in reading order and `next` stops there
      // first. Acceptable at the only width that reaches rung 3, and the
      // alternative (the category between the amount and the add button)
      // buys a tidier tab order by making the row look like a mistake.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (categorySharesTheLabelsLine)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                category,
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: label),
              ],
            )
          else
            label,
          const SizedBox(height: AppSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!categorySharesTheLabelsLine) ...[
                category,
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: amount),
              add,
            ],
          ),
        ],
      );
    });
  }
}
