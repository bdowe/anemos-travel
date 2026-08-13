import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

// The expense-category vocabulary, shared by BudgetSection and the
// booked-flip expense prompt. These are canonical API values sent to the
// server, so they are NEVER translated — only their display labels are
// (specs/i18n-spanish). The server bounds category to this exact set
// (default "general"); anything unexpected falls under "general".

/// Display order for the category groups.
const List<String> kExpenseCategories = [
  'flights',
  'lodging',
  'food',
  'activities',
  'transport',
  'shopping',
  'general',
];

String expenseCategoryLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'flights' => l10n.budgetCategoryFlights,
      'lodging' => l10n.budgetCategoryLodging,
      'food' => l10n.budgetCategoryFood,
      'activities' => l10n.budgetCategoryActivities,
      'transport' => l10n.budgetCategoryTransport,
      'shopping' => l10n.budgetCategoryShopping,
      'general' => l10n.budgetCategoryGeneral,
      _ => value,
    };

const Map<String, IconData> kExpenseCategoryIcons = {
  'flights': Icons.flight_outlined,
  'lodging': Icons.hotel_outlined,
  'food': Icons.restaurant_outlined,
  'activities': Icons.local_activity_outlined,
  'transport': Icons.directions_bus_outlined,
  'shopping': Icons.shopping_bag_outlined,
  'general': Icons.receipt_long_outlined,
};

String normalizeExpenseCategory(String raw) {
  final c = raw.trim().toLowerCase();
  return kExpenseCategories.contains(c) ? c : 'general';
}
