import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import 'status_pill.dart';

/// Promoted shortcut into the trip that is happening right now
/// (specs/happening-now). Same brand-gradient treatment as the home screen's
/// recent-trip tile, so it reads as the top-priority object wherever it sits;
/// shown above everything else on the trips list and in the recent-trip slot
/// on home. Tap goes straight to the trip detail, which auto-scrolls to today.
class LiveTripCard extends StatelessWidget {
  final Trip trip;
  final VoidCallback onTap;

  const LiveTripCard({super.key, required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    // Where the trip stands today: "Day N of M", or just "Day N" for an
    // open-ended trip (no end date => day count 0). The trips-list payload
    // carries no items, so the count comes from the date span alone.
    final day = tripDayOn(trip.startDate, trip.endDate, DateTime.now());
    final total = dayCount(trip.startDate, trip.endDate, const <int?>[]);
    final progress = day == null
        ? null
        : (total > 0 ? l10n.liveTripDayOfTotal(day, total) : l10n.liveTripDay(day));

    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadius.mdAll,
        gradient: AppColors.brandGradient,
        boxShadow: [
          BoxShadow(
            color: AppColors.brandDark.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm + 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child:
                      const Icon(Icons.near_me, color: Colors.white, size: 26),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.liveTripEyebrow,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white70,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // Real trip title, like the trips list and detail
                        // header; cities label only for legacy AI-summary
                        // titles (see tripTitleIsLong).
                        trip.title.isNotEmpty && !tripTitleIsLong(trip.title)
                            ? trip.title
                            : citiesLabel(
                                  trip.cities,
                                  two: (a, b) => l10n.citiesTwo(a, b),
                                  more: (a, b, n) =>
                                      l10n.citiesMore(a, b, n),
                                ) ??
                                trip.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: [
                          // White-tinted pill so it sits on the gradient like
                          // the rest of the card, not like the light-surface
                          // StatusPill used on the trips list.
                          StatusPill.custom(
                            label: l10n.liveTripStatusLive,
                            background: Colors.white.withValues(alpha: 0.22),
                            foreground: Colors.white,
                          ),
                          if (progress != null) ...[
                            const SizedBox(width: AppSpacing.sm),
                            Flexible(
                              child: Text(
                                progress,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.85),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios,
                    size: 16, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
