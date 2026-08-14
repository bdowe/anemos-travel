import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/trip_finding.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';

/// The "Next Step" CTA card (specs/next-step-cta): the single next planning
/// action for the trip, straight from the review payload's server-derived
/// ladder. Pure and provider-free — the screen supplies the step and wires the
/// callbacks — so it unit-tests without a harness.
///
/// Visual family: the tinted-banner idiom (`_ItineraryBanner`), not the
/// health sheet's severity colors — this card is guidance, not an alarm. The
/// `all_set` kind renders the success variant instead; a null [step] renders
/// nothing (the screen passes null while the review loads, for viewers, and
/// for past trips).
class NextStepCard extends StatelessWidget {
  final NextStep? step;
  final PlanProgress? progress;

  /// Narrow layouts: drop the detail line and the "View all" entry (the
  /// app-bar health badge stays the always-present overview on every width).
  final bool compact;

  /// Offline: the card stays visible but its actions are disabled — same
  /// treatment as the header Refine chip.
  final bool enabled;

  final VoidCallback? onPrimary;
  final VoidCallback? onViewAll;

  /// Dismisses the all_set celebration (session-scoped; the screen owns the
  /// bool). Only rendered on the all_set variant.
  final VoidCallback? onDismiss;

  const NextStepCard({
    super.key,
    required this.step,
    this.progress,
    this.compact = false,
    this.enabled = true,
    this.onPrimary,
    this.onViewAll,
    this.onDismiss,
  });

  static const _kindIcons = <String, IconData>{
    'set_dates': Icons.event_outlined,
    'plan_itinerary': Icons.map_outlined,
    'add_lodging': Icons.hotel_outlined,
    'add_transport': Icons.directions_transit_outlined,
    'schedule_items': Icons.schedule_outlined,
    'book_trip': Icons.confirmation_number_outlined,
    'add_packing': Icons.luggage_outlined,
  };

  /// Localized primary-action label per ladder kind. An unknown kind (a future
  /// ladder phase from a newer server) falls back to the fix's server-localized
  /// button label, else the generic "View all".
  String _actionLabel(AppLocalizations l10n) {
    final s = step!;
    switch (s.kind) {
      case 'set_dates':
        return l10n.nextStepSetDatesAction;
      case 'plan_itinerary':
        return l10n.nextStepPlanAction;
      case 'add_lodging':
        return l10n.nextStepLodgingAction;
      case 'add_transport':
        // Walk-derived transport steps carry the matched booking todo's mode
        // on the fix (specs/next-step-cta, itinerary-order walk), so the
        // label matches the checklist row's openLabelOverride — the card and
        // the row name the same handoff. Ground modes and fix-less fallback
        // steps (an older server) keep the generic label.
        return switch (s.fix?.mode) {
          'flight' => l10n.tripFindFlights,
          'ferry' => l10n.tripFindFerries,
          _ => l10n.nextStepTransportAction,
        };
      case 'schedule_items':
        return l10n.nextStepScheduleAction;
      case 'book_trip':
        return l10n.nextStepBookAction;
      case 'add_packing':
        return l10n.nextStepPackingAction;
      default:
        return s.fix?.label ?? l10n.nextStepViewAll;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = step;
    if (s == null) return const SizedBox.shrink();
    if (s.kind == 'all_set') return _buildAllSet(context, s);
    return _buildStep(context, s);
  }

  Widget _buildStep(BuildContext context, NextStep s) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    final eyebrowStyle = theme.textTheme.labelSmall?.copyWith(
      color: AppColors.brandDark,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    );
    var eyebrow = l10n.nextStepEyebrow.toUpperCase();
    final p = progress;
    if (p != null && p.total > 0) {
      final current = (p.done + 1).clamp(1, p.total);
      eyebrow = '$eyebrow · ${l10n.nextStepProgress(current, p.total)}';
    }

    final detail = s.detail;
    return Container(
      key: const ValueKey('next-step-card'),
      margin: const EdgeInsets.only(top: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.brandTint,
        borderRadius: AppRadius.mdAll,
      ),
      // The whole card is the primary action; the trailing button is the
      // explicit affordance for the same tap.
      child: InkWell(
        borderRadius: AppRadius.mdAll,
        onTap: enabled ? onPrimary : null,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Icon(_kindIcons[s.kind] ?? Icons.place_outlined,
                  color: AppColors.brand, size: 24),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(eyebrow, style: eyebrowStyle),
                    const SizedBox(height: 2),
                    Text(
                      s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: AppColors.brandDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!compact && detail != null && detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.brandDark.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              if (!compact && onViewAll != null) ...[
                TextButton(
                  key: const ValueKey('next-step-view-all'),
                  onPressed: enabled ? onViewAll : null,
                  child: Text(l10n.nextStepViewAll),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              FilledButton.tonal(
                key: const ValueKey('next-step-primary'),
                onPressed: enabled ? onPrimary : null,
                child: Text(_actionLabel(l10n)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAllSet(BuildContext context, NextStep s) {
    final theme = Theme.of(context);
    final detail = s.detail;
    return Container(
      key: const ValueKey('next-step-all-set'),
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.successContainer,
        borderRadius: AppRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline,
              color: AppColors.onSuccessContainer, size: 24),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppColors.onSuccessContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!compact && detail != null && detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSuccessContainer,
                    ),
                  ),
              ],
            ),
          ),
          if (onDismiss != null)
            IconButton(
              key: const ValueKey('next-step-dismiss'),
              tooltip: context.l10n.nextStepAllSetDismiss,
              icon: const Icon(Icons.close, size: 20),
              color: AppColors.onSuccessContainer,
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}
