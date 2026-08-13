import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/budget.dart';
import '../models/expense.dart';
import '../providers/budget_provider.dart';
import '../theme/spacing.dart';
import '../utils/money_format.dart';
import 'budget_target_dialog.dart';
import 'empty_state.dart';

/// The Budget tab's body: a single per-trip budget (one target in one
/// currency) with a spend headline + progress toward the target, a flat list
/// of expense line-items grouped by category with per-category subtotals, a
/// running total, and a remaining footer.
/// Self-contained — it owns its data via [budgetProvider] + [expensesProvider]
/// and reconciles mutations by invalidating both family keys. (The
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

// Display order for the category groups. These are canonical API values sent to
// the server, so they are NEVER translated — only their display labels are
// (specs/i18n-spanish). The server bounds category to this exact set (default
// "general"); anything unexpected falls under "general".
const List<String> _categoryOrder = [
  'flights',
  'lodging',
  'food',
  'activities',
  'transport',
  'shopping',
  'general',
];

String _categoryLabel(AppLocalizations l10n, String value) => switch (value) {
      'flights' => l10n.budgetCategoryFlights,
      'lodging' => l10n.budgetCategoryLodging,
      'food' => l10n.budgetCategoryFood,
      'activities' => l10n.budgetCategoryActivities,
      'transport' => l10n.budgetCategoryTransport,
      'shopping' => l10n.budgetCategoryShopping,
      'general' => l10n.budgetCategoryGeneral,
      _ => value,
    };

const Map<String, IconData> _categoryIcons = {
  'flights': Icons.flight_outlined,
  'lodging': Icons.hotel_outlined,
  'food': Icons.restaurant_outlined,
  'activities': Icons.local_activity_outlined,
  'transport': Icons.directions_bus_outlined,
  'shopping': Icons.shopping_bag_outlined,
  'general': Icons.receipt_long_outlined,
};

String _normalizeCategory(String raw) {
  final c = raw.trim().toLowerCase();
  return _categoryOrder.contains(c) ? c : 'general';
}

class _BudgetSectionState extends ConsumerState<BudgetSection> {
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  String _addCategory = 'general';
  bool _busy = false;

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
    setState(() => _busy = true);
    try {
      await op();
      ref.invalidate(budgetProvider(widget.tripId));
      ref.invalidate(expensesProvider(widget.tripId));
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
    _run(() async {
      await ref.read(budgetApiServiceProvider).addExpense(
            widget.tripId,
            category: _addCategory,
            label: label,
            amount: amount,
          );
      _labelController.clear();
      _amountController.clear();
    });
  }

  Future<void> _editExpense(Expense expense) async {
    if (_guard()) return;
    final l10n = context.l10n;
    final labelController = TextEditingController(text: expense.label);
    final amountController =
        TextEditingController(text: _trimAmount(expense.amount));
    var category = _normalizeCategory(expense.category);
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
                  for (final cat in _categoryOrder)
                    DropdownMenuItem(
                        value: cat, child: Text(_categoryLabel(l10n, cat))),
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
      byCategory.putIfAbsent(_normalizeCategory(e.category), () => []).add(e);
    }
    final widgets = <Widget>[];
    for (final cat in _categoryOrder) {
      final group = byCategory[cat];
      if (group == null || group.isEmpty) continue;
      final subtotal = group.fold<double>(0, (sum, e) => sum + e.amount);
      widgets.add(Padding(
        padding:
            const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
        child: Row(
          children: [
            Icon(_categoryIcons[cat],
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                _categoryLabel(context.l10n, cat),
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
        DropdownButton<String>(
          value: _addCategory,
          underline: const SizedBox.shrink(),
          onChanged: widget.isOffline
              ? null
              : (v) => setState(() => _addCategory = v ?? 'general'),
          // Closed state stays icon-only (the add row is width-tight on
          // phones); the open menu spells out each category.
          selectedItemBuilder: (context) => [
            for (final cat in _categoryOrder)
              Center(
                child: Icon(_categoryIcons[cat],
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
          items: [
            for (final cat in _categoryOrder)
              DropdownMenuItem(
                value: cat,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_categoryIcons[cat],
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpacing.sm),
                    Text(_categoryLabel(context.l10n, cat)),
                  ],
                ),
              ),
          ],
        ),
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
        SizedBox(
          width: 88,
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
