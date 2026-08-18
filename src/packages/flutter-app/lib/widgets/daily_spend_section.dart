import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/daily_spend.dart';
import '../models/expense.dart';
import '../providers/budget_provider.dart';
import '../theme/spacing.dart';
import '../utils/daily_spend.dart';
import '../utils/money_format.dart';

/// The Budget tab's "Daily food & drink" section: one row per city on the trip
/// with a per-person daily estimate, and one tap to file `rate × nights ×
/// travelers` as a **planned** food expense (specs/daily-spend-guide).
///
/// It sits below the totals and above the add row deliberately: it is an input
/// to planning, so it belongs beside the other way of adding a line — and it
/// must never push the real numbers down the page.
///
/// The number is a labelled estimate, and the subtitle says so on every render.
/// Nothing here may present it as a looked-up price; there is no free global
/// meal-price feed to look one up in (daily_spend_service.go).
///
/// Rendered only when there is something to show: the section disappears
/// entirely for viewers, offline, and any answer the server could not produce.
class DailySpendSection extends ConsumerWidget {
  final String tripId;
  final List<Expense> expenses;
  final bool isOffline;

  /// Files the accepted plan. Passed in rather than called here so the write
  /// goes through [BudgetSection]'s one `_run` — the single place that holds
  /// the busy flag, invalidates both budget providers and reports failure.
  final Future<void> Function(DailySpendCity city, double total, String label)
      onAdd;

  const DailySpendSection({
    super.key,
    required this.tripId,
    required this.expenses,
    required this.isOffline,
    required this.onAdd,
  });

  /// The line this city already has, or null. Found by IDENTITY — the leg key
  /// the server stamped (00070) — never by matching the label this widget
  /// generated, which is how a renamed line would silently duplicate itself.
  /// `legPlan` is load-bearing since 00072: a manually tagged Rome food line
  /// carries the same legKey and category, and without the flag this card
  /// would adopt the traveler's dinner as its plan.
  Expense? _planFor(DailySpendCity city) {
    for (final e in expenses) {
      if (e.legPlan &&
          e.legKey == city.legKey &&
          e.category == kDailySpendCategory) {
        return e;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isOffline) return const SizedBox.shrink();
    final settings = ref.watch(dailySpendSettingsProvider(tripId));
    final guide = ref
        .watch(dailySpendProvider(
            DailySpendQuery(tripId: tripId, tier: settings.tier)))
        .valueOrNull;
    // No spinner and no error box: until there is an answer, there is no
    // section. A suggestion is not worth a loading state over someone's money.
    if (guide == null || guide.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final l10n = context.l10n;

    // What the amount covers is a property of the TIER, not of the city, so in
    // practice every row comes back with the same phrase — printing it under
    // each one is the repetition `summarizeHotels` avoids by stating the bag
    // basis once. Shown once when they all agree, per row when they genuinely
    // differ; never both, and never a phrase that isn't a city's own.
    final phrases =
        guide.cities.map((c) => c.includes).where((s) => s.isNotEmpty).toList();
    final sharedIncludes =
        phrases.length == guide.cities.length && phrases.toSet().length == 1
            ? phrases.first
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Divider(height: 1),
        ),
        Text(
          l10n.budgetDailyTitle,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(
          l10n.budgetDailySubtitle,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (sharedIncludes != null)
          Text(
            sharedIncludes,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        // The two controls get their OWN LINE — the same call the planned/paid
        // control made, and for the same reason: side by side with the title
        // they overflow a 360px phone in Spanish ("Sin mirar el precio" sets
        // the dropdown's width). Wrap rather than Row so no text scale can
        // reintroduce it.
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.xs,
          children: [
            _TierControl(tripId: tripId, tier: guide.tier),
            _TravelersStepper(tripId: tripId, travelers: settings.travelers),
          ],
        ),
        // Credited only when a saved preference actually produced the tier, so
        // the line can never imply a choice the traveler never made.
        if (guide.tierSource == 'profile')
          Text(
            l10n.budgetDailyTierFromProfile,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        const SizedBox(height: AppSpacing.xs),
        for (final city in guide.cities)
          _CityRow(
            city: city,
            currency: guide.currency,
            travelers: settings.travelers,
            existing: _planFor(city),
            // Suppressed only because it is already stated above, verbatim.
            showIncludes: sharedIncludes == null,
            onAdd: onAdd,
          ),
      ],
    );
  }
}

/// One city: its nights, the per-person rate, and either the total with an
/// "Add to plan" button or the plan that is already filed.
class _CityRow extends StatelessWidget {
  final DailySpendCity city;
  final String currency;
  final int travelers;
  final Expense? existing;

  /// False when every city shares one phrase and the section states it once.
  final bool showIncludes;
  final Future<void> Function(DailySpendCity city, double total, String label)
      onAdd;

  const _CityRow({
    required this.city,
    required this.currency,
    required this.travelers,
    required this.existing,
    required this.showIncludes,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final total = dailySpendTotal(
      dailyAmount: city.dailyAmount,
      nights: city.nights,
      travelers: travelers,
    );
    final planned = existing?.plannedFor ?? existing?.amount;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${city.label} · ${l10n.budgetDailyNights(city.nights)}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  l10n.budgetDailyRate(
                      formatMoney(city.dailyAmount, currency)),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (showIncludes && city.includes.isNotEmpty)
                  Text(
                    city.includes,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          // Once a city is in the plan the card shows THAT number, not the
          // suggestion: the line is the traveler's from the moment it exists,
          // and it is edited in the list above like any other.
          if (existing != null)
            Text(
              l10n.budgetDailyInPlan(formatMoney(planned ?? 0, currency)),
              key: ValueKey('dailySpendInPlan_${city.legKey}'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatMoney(total, currency),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                TextButton(
                  key: ValueKey('dailySpendAdd_${city.legKey}'),
                  onPressed: () => onAdd(
                    city,
                    total,
                    l10n.budgetDailyExpenseLabel(city.label),
                  ),
                  child: Text(l10n.budgetDailyAdd),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Which spending level to price at. A [PopupMenuButton] would be the THIRD one
/// in this tab — the expense row menu and the add row's category picker are
/// both `PopupMenuButton<String>` — so this carries a key and its own type to
/// keep both the widget tree and its tests unambiguous.
class _TierControl extends ConsumerWidget {
  final String tripId;
  final String tier;

  const _TierControl({required this.tripId, required this.tier});

  static const List<String> _tiers = ['budget', 'mid', 'luxury'];

  String _label(BuildContext context, String value) {
    final l10n = context.l10n;
    switch (value) {
      case 'budget':
        return l10n.budgetDailyTierBudget;
      case 'luxury':
        return l10n.budgetDailyTierLuxury;
      default:
        return l10n.budgetDailyTierMid;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: const ValueKey('dailySpendTier'),
        value: _tiers.contains(tier) ? tier : 'mid',
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        style: Theme.of(context).textTheme.bodySmall,
        onChanged: (next) {
          if (next == null) return;
          ref.read(dailySpendSettingsProvider(tripId).notifier).setTier(next);
        },
        items: [
          for (final t in _tiers)
            DropdownMenuItem(value: t, child: Text(_label(context, t))),
        ],
      ),
    );
  }
}

/// How many people are eating. Session-local: a trip stores no party size, and
/// inferring one from `traveler_preferences.companions` would be guessing a
/// headcount from a taste.
class _TravelersStepper extends ConsumerWidget {
  final String tripId;
  final int travelers;

  const _TravelersStepper({required this.tripId, required this.travelers});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final notifier = ref.read(dailySpendSettingsProvider(tripId).notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('dailySpendTravelersRemove'),
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: l10n.budgetDailyTravelersRemove,
          onPressed: travelers > kDailySpendMinTravelers
              ? () => notifier.setTravelers(travelers - 1)
              : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(
          l10n.budgetDailyTravelers(travelers),
          key: const ValueKey('dailySpendTravelers'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        IconButton(
          key: const ValueKey('dailySpendTravelersAdd'),
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: l10n.budgetDailyTravelersAdd,
          onPressed: travelers < kDailySpendMaxTravelers
              ? () => notifier.setTravelers(travelers + 1)
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}
