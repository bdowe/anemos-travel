import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/budget.dart';
import '../models/expense.dart';
import '../providers/budget_provider.dart';
import '../theme/spacing.dart';
import '../utils/money_format.dart';
import 'budget_categories.dart';
import 'budget_target_dialog.dart';
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
// with the booked-flip expense prompt.

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

  void _add() {
    final label = _labelController.text.trim();
    final amount = double.tryParse(_amountController.text.trim());
    if (label.isEmpty || amount == null || amount < 0) return;
    final key = expenseDraftProvider(widget.tripId);
    final category = ref.read(key).category;
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
          );
      if (mounted) {
        _labelController.clear();
        _amountController.clear();
      }
      draft.clearText();
    });
  }

  Future<void> _editExpense(Expense expense) async {
    if (_guard()) return;
    final l10n = context.l10n;
    final labelController = TextEditingController(text: expense.label);
    final amountController =
        TextEditingController(text: _trimAmount(expense.amount));
    var category = normalizeExpenseCategory(expense.category);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l10n.budgetEditExpenseTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
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
                controller: amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(labelText: l10n.budgetAmount),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l10n.commonCancel)),
            FilledButton(
              onPressed: () {
                final label = labelController.text.trim();
                final amount = double.tryParse(amountController.text.trim());
                if (label.isEmpty || amount == null || amount < 0) return;
                Navigator.of(ctx).pop({
                  'category': category,
                  'label': label,
                  'amount': amount,
                });
              },
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      _run(() => ref
          .read(budgetApiServiceProvider)
          .updateExpense(widget.tripId, expense.id, result));
    }
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
          const SizedBox(height: AppSpacing.sm),
          _buildAddRow(theme),
        ],
      ],
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
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      // Clamped: the bar caps at full; "over" signals through
                      // the error color (bar + headline) and the negative
                      // Remaining line below.
                      value: (budget.spent / budget.targetAmount!)
                          .clamp(0.0, 1.0)
                          .toDouble(),
                      minHeight: 6,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      color: over
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      semanticsLabel: l10n.budgetTitle,
                      semanticsValue: '$pct%',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '$pct%',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ],
      ),
    );
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
      final subtotal = group.fold<double>(0, (sum, e) => sum + e.amount);
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
    return Padding(
      key: ValueKey(expense.id),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Text(
              expense.label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
          Text(
            formatMoney(expense.amount, currency),
            style: theme.textTheme.bodyMedium,
          ),
          if (widget.canEdit)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
              tooltip: context.l10n.budgetExpenseOptions,
              onSelected: (v) {
                if (v == 'edit') _editExpense(expense);
                if (v == 'delete') _delete(expense);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'edit', child: Text(context.l10n.budgetMenuEdit)),
                PopupMenuItem(
                    value: 'delete', child: Text(context.l10n.commonDelete)),
              ],
            )
          else
            const SizedBox(width: AppSpacing.sm),
        ],
      ),
    );
  }

  Widget _buildTotals(ThemeData theme, Budget budget, List<Expense> expenses) {
    final currency = budget.currency;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Divider(height: 1),
        ),
        Row(
          children: [
            Expanded(
              child: Text(context.l10n.budgetTotalSpent,
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
        if (budget.remaining != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(context.l10n.budgetRemaining,
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

  Widget _buildAddRow(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Closed state stays icon-compact (the add row is width-tight on
        // phones); the open menu spells out each category. A popup menu (not
        // a DropdownButton) because a dropdown's menu is hard-constrained to
        // the trigger's width — an icon-only trigger would clip every label.
        //
        // The pick is read straight from the draft rather than mirrored into a
        // field, so there is one answer to "which category is armed". The
        // watch is scoped to this button and selects one String, so typing in
        // the fields beside it can never re-render the expense list.
        Consumer(builder: (context, ref, _) {
          final category = ref.watch(
              expenseDraftProvider(widget.tripId).select((d) => d.category));
          return PopupMenuButton<String>(
            tooltip: context.l10n.budgetCategoryLabel,
            enabled: !widget.isOffline,
            position: PopupMenuPosition.under,
            color: theme.colorScheme.surface,
            elevation: 3,
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
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
          );
        }),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: TextField(
            controller: _labelController,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              isDense: true,
              hintText: context.l10n.budgetAddHint,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        // 136 leaves a 104px interior after the theme's filled-field content
        // padding (16px per side) — fits "Amount"/"Importe" in Inter with
        // text-scale headroom, and fits the 1em-per-glyph FlutterTest font
        // ("Amount" = 99px incl. letter-spacing) the regression test
        // measures with.
        SizedBox(
          width: 136,
          child: TextField(
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
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: context.l10n.budgetAddExpenseTooltip,
          onPressed: widget.isOffline ? null : _add,
        ),
      ],
    );
  }
}
