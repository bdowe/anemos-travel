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

  /// Narrow layouts: drop the detail line and the Trip-health entry (the
  /// app-bar health badge stays the always-present overview on every width).
  /// The eyebrow's progress entry survives compaction on purpose — it is the
  /// only thing that explains the counter, and the counter renders at every
  /// width.
  final bool compact;

  /// Offline: the card stays visible but its actions are disabled — same
  /// treatment as the header Refine chip.
  final bool enabled;

  final VoidCallback? onPrimary;
  final VoidCallback? onViewAll;

  /// Opens the plan-progress sheet from the eyebrow's "N of 6" counter
  /// (specs/next-step-cta). Null hides the affordance and leaves the plain
  /// eyebrow — which is what a payload with no ladder (older server, cached
  /// response) gets, since there would be nothing to show.
  ///
  /// Deliberately NOT gated on [enabled]: the sheet is a pure render of the
  /// payload already on screen, so explaining the counter keeps working
  /// offline even though every action on the card is disabled there.
  final VoidCallback? onViewProgress;

  /// Dismisses the all_set celebration (session-scoped; the screen owns the
  /// bool). Only rendered on the all_set variant.
  final VoidCallback? onDismiss;

  /// Whether a transport step will hand off to a provider (in-app flight
  /// search / Ferryhopper) rather than open the seeded chat. Only the screen
  /// can know — the handoff needs a synced booking row the card never sees —
  /// so it injects the fact and the card keeps owning the copy. False makes
  /// the button say the generic "Find options" it actually does, instead of
  /// promising "Find flights" and opening a chat.
  final bool transportHandsOff;

  const NextStepCard({
    super.key,
    required this.step,
    this.progress,
    this.compact = false,
    this.enabled = true,
    this.onPrimary,
    this.onViewAll,
    this.onViewProgress,
    this.onDismiss,
    this.transportHandsOff = false,
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

  /// The ladder's icon for [kind], falling back to the same generic pin this
  /// card uses for an unknown kind (a future phase from a newer server).
  ///
  /// Public because Home renders the same step as a quiet band under its
  /// continue hero ([HomeNextStepBand]) and the two must never disagree about
  /// what a step looks like. The map itself stays private — a second literal
  /// copy of it is exactly the drift this accessor exists to prevent.
  static IconData iconFor(String kind) =>
      _kindIcons[kind] ?? Icons.place_outlined;

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
        // The button names what the tap will DO. Only a step that hands off
        // to a provider gets the row's own wording (specs/next-step-cta,
        // itinerary-order walk) — so the card and the checklist row name the
        // same handoff. Everything else (ground modes, a findings-fallback
        // step whose fix carries a mode but has no synced row behind it, an
        // older server) keeps the generic label and opens the seeded chat.
        if (!transportHandsOff) return l10n.nextStepTransportAction;
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
    // The tinted-panel family, resolved once per build. Fixed light constants
    // here painted teal-50 under teal-900 text in BOTH themes, so dark mode
    // opened on a light mint block; the pair now tracks the brightness (and,
    // in dark, the seed) — see [AppColors.brandTintFill].
    final scheme = theme.colorScheme;
    final tintFill = AppColors.brandTintFill(scheme);
    final tintInk = AppColors.onBrandTint(scheme);

    final eyebrowStyle = theme.textTheme.labelSmall?.copyWith(
      color: tintInk,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    );
    var eyebrow = l10n.nextStepEyebrow.toUpperCase();
    final p = progress;
    final counted = p != null && p.total > 0;
    if (counted) {
      final current = (p.done + 1).clamp(1, p.total);
      eyebrow = '$eyebrow · ${l10n.nextStepProgress(current, p.total)}';
    }
    // A counter nobody can expand is a dead end ("3 of 6" — of WHAT?), so the
    // eyebrow itself opens the ladder. It lives inside the card-wide InkWell:
    // the inner recognizer wins the tap, so opening the sheet never also fires
    // the primary action (pinned by next_step_card_test).
    final eyebrowText = Text(eyebrow, style: eyebrowStyle);
    Widget eyebrowLine = eyebrowText;
    if (counted && onViewProgress != null) {
      eyebrowLine = Tooltip(
        message: l10n.nextStepViewProgress,
        child: InkWell(
          key: const ValueKey('next-step-progress'),
          onTap: onViewProgress,
          borderRadius: AppRadius.smAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Flexible, not bare: on a phone the eyebrow already wraps to
                // two lines beside the action button, and the counter is the
                // one thing here that must never be clipped away.
                Flexible(child: eyebrowText),
                Icon(Icons.expand_more, size: 14, color: tintInk),
              ],
            ),
          ),
        ),
      );
    }

    final detail = s.detail;
    return Container(
      key: const ValueKey('next-step-card'),
      margin: const EdgeInsets.only(top: AppSpacing.md),
      decoration: BoxDecoration(
        color: tintFill,
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
                  color: AppColors.brandTintAccent(scheme), size: 24),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    eyebrowLine,
                    const SizedBox(height: 2),
                    Text(
                      s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: tintInk,
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
                          color: tintInk.withValues(alpha: 0.85),
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
                  // Named for where it goes. Beside a step counter, "View all"
                  // promised the steps and delivered the findings list; the
                  // sheet's own title says what this really opens.
                  child: Text(l10n.reviewSectionTitle),
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
