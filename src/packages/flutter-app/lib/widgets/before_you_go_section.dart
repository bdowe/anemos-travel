import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/trip_finding.dart';
import '../providers/trip_review_provider.dart';
import '../theme/spacing.dart';
import '../utils/trip_days.dart';
import 'section_header.dart';

/// What the trip you are about to take still has open, on Home.
///
/// The rows are the review's own [TripFinding]s — the same server-derived list
/// behind the trip page's health sheet — so nothing here is computed twice and
/// nothing is invented. It reads them off the review [HomeNextStepBand] has
/// already fetched for this trip, so the whole section costs **no additional
/// request**: same provider, same family key, one cached call.
///
/// **Windowed, not permanent furniture.** It appears only inside
/// [_windowDays] of departure. A trip eleven months out always has open items
/// — that is what planning is — and listing them every time Home loads would
/// turn a real pre-departure signal into wallpaper that gets scrolled past.
/// Past and undated trips never qualify.
///
/// The step already promoted into the band above is filtered out by category,
/// so the two never say the same thing twice. Everything left is capped at
/// [_maxRows]: this is a nudge toward the trip page, not a second health
/// sheet, and the sheet is one tap away with the complete list.
///
/// Renders nothing when the window is closed, the review has not arrived, or
/// nothing is open — an empty "Before you go" is worse than no section.
class BeforeYouGoSection extends ConsumerWidget {
  final String tripId;

  /// ISO date-only trip start. Null means the snapshot could not say, which
  /// closes the window rather than guessing it open.
  final String? startDate;

  const BeforeYouGoSection({
    super.key,
    required this.tripId,
    required this.startDate,
  });

  /// How close departure has to be. Two weeks is the span where lodging,
  /// transport and packing stop being plans and start being errands.
  static const int _windowDays = 14;

  static const int _maxRows = 3;

  /// Which finding category each ladder step speaks for, so the band above and
  /// the rows below cannot both report the same gap. Kinds absent from this
  /// map (a future phase from a newer server) filter nothing, which shows one
  /// duplicate row at worst — strictly better than hiding a real finding
  /// because an unknown kind matched nothing.
  static const _stepCategory = <String, String>{
    'set_dates': 'dates',
    'plan_itinerary': 'unscheduled',
    'schedule_items': 'unscheduled',
    'add_lodging': 'lodging',
    'add_transport': 'transit',
    'add_packing': 'packing',
    'book_trip': 'bookings',
  };

  static const _categoryIcons = <String, IconData>{
    'dates': Icons.event_outlined,
    'unscheduled': Icons.schedule_outlined,
    'packing': Icons.luggage_outlined,
    'lodging': Icons.hotel_outlined,
    'transit': Icons.directions_transit_outlined,
    'budget': Icons.account_balance_wallet_outlined,
    'bookings': Icons.confirmation_number_outlined,
  };

  /// critical first, then warn, then info — the order a traveler with four
  /// days left needs them in. Stable within a severity: the server's own
  /// ordering survives, so the list does not reshuffle between builds.
  static const _severityRank = <String, int>{
    'critical': 0,
    'warn': 1,
    'info': 2,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = daysUntilTrip(startDate, DateTime.now());
    if (days == null || days > _windowDays) return const SizedBox.shrink();

    final review = ref.watch(tripReviewProvider(TripReviewKey(tripId)));
    final value = review.valueOrNull;
    if (value == null) return const SizedBox.shrink();

    final promoted = _stepCategory[value.nextStep?.kind ?? ''];
    final rows = <TripFinding>[
      for (final f in value.findings)
        if (f.category != promoted) f
    ]..sort((a, b) => (_severityRank[a.severity] ?? 2)
        .compareTo(_severityRank[b.severity] ?? 2));
    if (rows.isEmpty) return const SizedBox.shrink();

    final shown = rows.take(_maxRows).toList();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: context.l10n.homeBeforeYouGoTitle),
        const SizedBox(height: AppSpacing.md),
        Card(
          // Rows, not tiles: DESIGN.md rules out same-size icon cards as page
          // structure and the hero-metric template, and a readiness list is
          // exactly where both are tempting.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++)
                  _FindingRow(
                    finding: shown[i],
                    icon: _categoryIcons[shown[i].category] ??
                        Icons.info_outline,
                    showDivider: i < shown.length - 1,
                  ),
              ],
            ),
          ),
        ),
        if (rows.length > shown.length)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              context.l10n.homeBeforeYouGoMore(rows.length - shown.length),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

/// One open item. Not tappable: applying a fix needs the trip screen's
/// mutation providers, and a row that looks actionable but only navigates is
/// the same broken promise [HomeNextStepBand] refuses to make.
class _FindingRow extends StatelessWidget {
  final TripFinding finding;
  final IconData icon;
  final bool showDivider;

  const _FindingRow({
    required this.finding,
    required this.icon,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        ConstrainedBox(
          // The house touch floor, kept even though the row is not a target:
          // it is what makes a list of three read as a list rather than a
          // paragraph with icons.
          constraints: const BoxConstraints(minHeight: kMinTouchTarget),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // outlineVariant for info, exactly as the status vocabulary
              // does: absence of urgency must never read as a severity.
              Icon(icon,
                  size: 20,
                  color: finding.severity == 'info'
                      ? scheme.onSurfaceVariant
                      : scheme.primary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text(
                    finding.message,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (showDivider) Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }
}
