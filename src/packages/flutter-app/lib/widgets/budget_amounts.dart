import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/expense.dart';
import '../utils/money_format.dart';

// budget_amounts.dart — the planned-vs-paid vocabulary of the Budget tab, kept
// out of budget_section.dart so the arithmetic is unit-testable and the two
// small widgets can be reused (precedent: budget_categories.dart, shared with
// the booked-flip prompt).
//
// The TOTALS are not here: `planned`, `spent`, `projected` and `plan_variance`
// are derived once on the server (sumExpenses) and read off [Budget]. What is
// here is per-row and per-group rendering, which the server has no business
// knowing about.

/// Width of the leading state column. Replaces the dead indent the row used to
/// carry, so a row gains a state signal without getting wider.
const double kExpenseGlyphSlot = 28;

/// The ONE definition of "this line has been paid" on the Dart side, mirroring
/// `expensePurchased` in budget_handler.go. Goes through [Expense.paidAmount]
/// rather than the `purchased` flag so a payload that predates the split still
/// reads correctly.
bool expenseIsPaid(Expense e) => e.paidAmount != null;

/// What this line contributes to the trip's projected cost: what it cost if
/// known, otherwise what it is planned at.
double expenseProjected(Expense e) => e.paidAmount ?? e.plannedFor ?? e.amount;

/// A category group's subtotal. Deliberately ONE number — the projected one,
/// which is the only subtotal that stays continuous across a trip (it equals
/// the plan before departure and the spend after it). Two numbers per group
/// turns the section into a spreadsheet.
double groupProjectedSubtotal(Iterable<Expense> expenses) =>
    expenses.fold<double>(0, (sum, e) => sum + expenseProjected(e));

/// True when a group still contains money that hasn't left yet — the group
/// header shows a small planned marker so a subtotal can't read as settled.
bool groupHasPlanned(Iterable<Expense> expenses) =>
    expenses.any((e) => !expenseIsPaid(e));

/// The leading ○ / ✓ on an expense row: hollow while a line is only planned,
/// filled once it is paid. Deliberately the check-it-off metaphor the Booked
/// checkbox already uses.
///
/// [onTap] is null for viewers, offline, and `auto` rows — a booking-created
/// line is a mirror of its booking, so it is un-paid by un-booking, not here.
class ExpenseStateGlyph extends StatelessWidget {
  final bool paid;
  final VoidCallback? onTap;

  /// Overrides the tooltip; used for the `auto` row's "un-book it" explanation.
  final String? tooltip;

  const ExpenseStateGlyph({
    super.key,
    required this.paid,
    this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final label =
        paid ? l10n.budgetPlanStatePaid : l10n.budgetPlanStatePlanned;
    final icon = Icon(
      paid ? Icons.check_circle : Icons.radio_button_unchecked,
      size: 14,
      color: paid ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
    );

    if (onTap == null) {
      return SizedBox(
        width: kExpenseGlyphSlot,
        child: Semantics(
          label: tooltip ?? label,
          child: tooltip == null
              ? icon
              : Tooltip(message: tooltip!, child: icon),
        ),
      );
    }
    return SizedBox(
      width: kExpenseGlyphSlot,
      child: Tooltip(
        message: paid ? l10n.budgetPlanMarkPlanned : l10n.budgetPlanMarkPaid,
        child: Semantics(
          button: true,
          label: paid ? l10n.budgetPlanMarkPlanned : l10n.budgetPlanMarkPaid,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              child: icon,
            ),
          ),
        ),
      ),
    );
  }
}

/// The trailing money cell of an expense row: one number, or `$1,100→$1,150`
/// when a line was planned at one price and paid at another.
///
/// Non-flexible on purpose — RenderFlex lays out non-flexible children first,
/// so the amount always gets the width it needs and the label absorbs the rest
/// by wrapping. Overflow is structurally impossible, at any text scale.
class ExpenseAmountCell extends StatelessWidget {
  final Expense expense;
  final String currency;

  const ExpenseAmountCell({
    super.key,
    required this.expense,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final paid = expense.paidAmount;
    final planned = expense.plannedFor;

    if (!expense.showsPair) {
      // One number: what it cost, or what it is planned at. Planned money is
      // muted — it hasn't happened yet.
      final only = paid ?? planned ?? expense.amount;
      return Text(
        formatMoney(only, currency),
        style: base?.copyWith(
          color: paid == null
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.onSurface,
        ),
      );
    }

    final plannedText = formatMoney(planned!, currency);
    final paidText = formatMoney(paid!, currency);
    return Semantics(
      label: context.l10n.budgetPlanRowBothSemantics(plannedText, paidText),
      child: ExcludeSemantics(
        child: Text.rich(
          TextSpan(children: [
            TextSpan(
              text: plannedText,
              style: base?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            TextSpan(
              text: '→',
              style: base?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            TextSpan(
              text: paidText,
              style: base?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
