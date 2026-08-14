import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/booking_todo.dart';
import '../models/trip_segment.dart';
import 'budget_categories.dart';

/// The booked-flip "Add to budget?" flow's pure pieces (specs/budget-v2 PR B):
/// prefill derivation + the Save/Skip dialog. Deliberately UX-agnostic — the
/// trigger site in trip_detail_screen owns WHEN to ask (dialog right after
/// the flip today; a snackbar-action variant would call the same function),
/// and all mapping/dedupe/save/undo logic lives outside this file's dialog.

/// What the prompt pre-fills from the booking row(s) being flipped.
class BookedExpensePrefill {
  final String category;
  final String label;
  const BookedExpensePrefill({required this.category, required this.label});
}

/// What the traveler confirmed in the dialog.
class BookedExpenseDraft {
  final String category;
  final String label;
  final double amount;
  const BookedExpenseDraft(
      {required this.category, required this.label, required this.amount});
}

/// Maps the flipped row(s) to a category + label. The confirmed record wins
/// over the todo (it carries the durable details): stay → lodging + name;
/// segment → flights when mode=='flight' else transport + "origin → dest".
/// Todo-only rows map by kind, with `mode` (the per-leg transport menu,
/// 00055) refining transport todos to flights.
BookedExpensePrefill deriveBookedExpensePrefill(
    {BookingTodo? todo, Accommodation? stay, TripSegment? segment}) {
  if (stay != null) {
    return BookedExpensePrefill(category: 'lodging', label: stay.name);
  }
  if (segment != null) {
    final route = [
      segment.origin?.trim() ?? '',
      segment.destination?.trim() ?? ''
    ].where((s) => s.isNotEmpty).join(' → ');
    return BookedExpensePrefill(
      category: segment.mode == 'flight' ? 'flights' : 'transport',
      label: route.isNotEmpty ? route : (todo?.title ?? segment.mode),
    );
  }
  final t = todo!;
  final category = switch (t.kind) {
    'stay' => 'lodging',
    'transport' => t.mode == 'flight' || t.mode == null ? 'flights' : 'transport',
    _ => 'general',
  };
  return BookedExpensePrefill(category: category, label: t.title);
}

/// Shows the "Add to budget?" dialog: pre-picked category, prefilled editable
/// label, autofocused amount labeled with the budget [currency]. Returns null
/// on Skip/dismiss. The caller saves (this dialog never touches the network).
Future<BookedExpenseDraft?> showBookedExpensePrompt(BuildContext context,
    {required String currency, required BookedExpensePrefill prefill}) {
  final l10n = context.l10n;
  final labelController = TextEditingController(text: prefill.label);
  final amountController = TextEditingController();
  var category = normalizeExpenseCategory(prefill.category);
  return showDialog<BookedExpenseDraft>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(l10n.budgetPromptTitle),
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
                    value: cat,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(kExpenseCategoryIcons[cat], size: 18),
                        const SizedBox(width: 8),
                        Text(expenseCategoryLabel(l10n, cat)),
                      ],
                    ),
                  ),
              ],
            ),
            TextField(
              controller: labelController,
              decoration: InputDecoration(labelText: l10n.budgetLabelField),
            ),
            TextField(
              controller: amountController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                  labelText: l10n.budgetPromptAmountLabel(currency)),
              onSubmitted: (_) => _save(ctx, category, labelController,
                  amountController),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.budgetPromptSkip),
          ),
          FilledButton(
            onPressed: () =>
                _save(ctx, category, labelController, amountController),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    ),
  );
}

void _save(BuildContext ctx, String category,
    TextEditingController labelController,
    TextEditingController amountController) {
  final label = labelController.text.trim();
  final amount = double.tryParse(amountController.text.trim());
  if (label.isEmpty || amount == null || amount < 0) return;
  Navigator.of(ctx)
      .pop(BookedExpenseDraft(category: category, label: label, amount: amount));
}
