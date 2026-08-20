import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/trip_review_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import 'next_step_card.dart';

/// The continue-trip hero's quiet sequel on Home: the one planning action that
/// trip still needs, from the same server-derived ladder the trip page renders
/// (`specs/next-step-cta`, [NextStepCard]).
///
/// Home used to say "here is your trip" and stop, which left a traveler four
/// days from departure with no idea that six nights in Kraków were unbooked —
/// the fact was computed, shipped in the review payload, and only visible to
/// someone who opened the trip. This band is that fact, one screen earlier.
///
/// **Deliberately not [NextStepCard].** That card's whole contract is that its
/// button names what the tap will DO ("Find lodging", and `transportHandsOff`
/// exists purely so the label can never promise a handoff the action won't
/// make). Home cannot honor that: the apply-fix plumbing lives on the trip
/// screen with the mutation providers, so a button here would say "Find
/// lodging" and deliver a navigation. So this band carries **no action
/// button** — it states the step and inherits the hero's tap. The traveler
/// lands on the trip with the real button under their thumb.
///
/// It is a band and not a second card for the same reason the saved-
/// conversation row under [NextStepCard] is one: flat, `AppSpacing.sm` beneath
/// its primary block (the gap `ContinueChatsSection` already puts after its
/// `leading`), so the pair scans as one plan block whose second line is
/// quieter than its first. A shadow here would put the secondary entry above
/// the primary one in depth.
///
/// Renders nothing while the review loads, on error, for a step-less payload,
/// and on `all_set` — Home is not where a celebration belongs, and an empty
/// band under the hero would be worse than no band. That absence is also why
/// this is safe to mount unconditionally: the section it decorates only exists
/// when there is a trip to continue.
class HomeNextStepBand extends ConsumerWidget {
  final String tripId;

  /// Where the band goes — the same destination the hero above it opens, so
  /// the pair is one target with two rows rather than two competing taps.
  final VoidCallback onTap;

  const HomeNextStepBand({
    super.key,
    required this.tripId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // valueOrNull, never `.when`: a spinner or an error box under the hero
    // would be louder than the fact it is waiting for. Absence is the loading
    // state and the error state both.
    final review = ref.watch(tripReviewProvider(TripReviewKey(tripId)));
    final step = review.valueOrNull?.nextStep;
    if (step == null || step.kind == 'all_set') return const SizedBox.shrink();

    final theme = Theme.of(context);
    final l10n = context.l10n;
    final scheme = theme.colorScheme;
    final tintFill = AppColors.brandTintFill(scheme);
    final tintInk = AppColors.onBrandTint(scheme);

    final progress = review.valueOrNull?.planProgress;
    final counted = progress != null && progress.total > 0;
    final detail = step.detail;

    return Semantics(
      button: true,
      container: true,
      child: Material(
        color: tintFill,
        borderRadius: AppRadius.mdAll,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Shared with the card on the trip page rather than re-listed
                // here, so one step cannot wear two icons across two screens.
                Icon(NextStepCard.iconFor(step.kind),
                    color: AppColors.brandTintAccent(scheme), size: 24),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: tintInk),
                      ),
                      if (detail != null && detail.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tintInk.withValues(alpha: 0.78),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // The counter only, never the card's "NEXT STEP ·" eyebrow:
                // capitals belong to the wordmark and the one place eyebrow
                // (DESIGN.md, the One Eyebrow Rule), and the icon beside the
                // title already says this is a task. Unlike the card's, this
                // counter does not open the ladder sheet — the trip page is
                // one tap away and owns that affordance.
                if (counted) ...[
                  const SizedBox(width: AppSpacing.md),
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      l10n.nextStepProgress(
                        (progress.done + 1).clamp(1, progress.total),
                        progress.total,
                      ),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: tintInk.withValues(alpha: 0.78),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
