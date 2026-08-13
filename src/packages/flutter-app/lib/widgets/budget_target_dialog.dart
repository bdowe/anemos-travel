import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/budget.dart';
import '../providers/budget_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';

// The currency codes formatMoney knows a symbol for — offered in the target
// dialog's dropdown. USD is the default.
const List<String> kBudgetCurrencyCodes = [
  'USD',
  'EUR',
  'GBP',
  'JPY',
  'CNY',
  'AUD',
  'CAD',
  'NZD',
  'HKD',
  'SGD',
  'MXN',
  'BRL',
  'INR',
  'KRW',
  'THB',
  'TRY',
];

/// THE budget-target editor (amount + currency), shared by [BudgetSection]'s
/// pencil and the trip screen's `raise_budget` health fix — one dialog, one
/// save path, so the two can't drift (they used to: the screen copy had no
/// currency picker). Saves on confirm, invalidates both budget providers,
/// and surfaces failures itself; returns true when a save happened. The
/// caller owns offline-guarding and any post-save follow-up.
Future<bool> showBudgetTargetDialog(
    BuildContext context, WidgetRef ref, String tripId, Budget budget) async {
  final l10n = context.l10n;
  final amountController = TextEditingController(
      text: budget.targetAmount == null
          ? ''
          : _trimAmount(budget.targetAmount!));
  var currency = kBudgetCurrencyCodes.contains(budget.currency)
      ? budget.currency
      : 'USD';
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(l10n.budgetSetTargetTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 96,
                  child: DropdownButtonFormField<String>(
                    initialValue: currency,
                    decoration:
                        InputDecoration(labelText: l10n.budgetCurrencyLabel),
                    onChanged: (v) => setLocal(() => currency = v ?? 'USD'),
                    items: [
                      for (final code in kBudgetCurrencyCodes)
                        DropdownMenuItem(value: code, child: Text(code)),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: amountController,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(
                      labelText: l10n.budgetTargetLabel,
                      hintText: l10n.budgetTargetHint,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.budgetTargetHelp,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () {
              final raw = amountController.text.trim();
              final amount = raw.isEmpty ? null : double.tryParse(raw);
              if (raw.isNotEmpty && (amount == null || amount < 0)) return;
              Navigator.of(ctx).pop({
                'target_amount': amount,
                'currency': currency,
              });
            },
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    ),
  );
  if (result == null) return false; // cancelled
  try {
    await ref.read(budgetApiServiceProvider).upsertBudget(
          tripId,
          targetAmount: result['target_amount'] as double?,
          currency: result['currency'] as String,
        );
    ref.invalidate(budgetProvider(tripId));
    ref.invalidate(expensesProvider(tripId));
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.tripUpdateBudgetFailed(friendlyError(l10n, e)))));
    }
    return false;
  }
}

// Whole units for editing (prices are quoted that way); drop a trailing ".0".
String _trimAmount(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();
