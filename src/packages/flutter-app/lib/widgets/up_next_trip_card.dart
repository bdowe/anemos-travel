import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../theme/app_colors.dart';
import '../theme/app_shadows.dart';
import '../theme/spacing.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import 'status_pill.dart';
import 'trip_map_band.dart';

/// The soonest upcoming trip, promoted to a hero at the head of the trips
/// list — the pre-trip sibling of [LiveTripCard] (same brand-gradient card
/// language), with a countdown pill instead of a Live pill and the cached
/// route map as a band on top. The hero REPLACES the trip's plain list card
/// (unlike the live spotlight, it shows strictly more than the card would),
/// and it never renders while a live trip exists — one promoted object at a
/// time. Tap goes straight to the trip detail.
class UpNextTripCard extends StatelessWidget {
  final Trip trip;
  final VoidCallback onTap;

  const UpNextTripCard({super.key, required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    final cities = citiesLabel(
      trip.cities,
      two: (a, b) => l10n.citiesTwo(a, b),
      more: (a, b, n) => l10n.citiesMore(a, b, n),
    );
    final headline = tripHeadline(trip.title, cities);
    final showCitiesLine = cities != null && headline != cities;
    final days = daysUntilTrip(trip.startDate, DateTime.now());
    final range = tripDateRange(trip.startDate, trip.endDate);

    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadius.mdAll,
        gradient: AppColors.brandGradient,
        boxShadow: AppShadows.brandCard,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.mdAll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Cached route preview; collapses to nothing on a cache miss
              // (trip never opened on this device) or an unmappable trip,
              // leaving the gradient card on its own — TripMapBand's
              // contract.
              TripMapBand(tripId: trip.id),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.sm + 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.flight_takeoff,
                          color: Colors.white, size: 26),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.upNextEyebrow,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white70,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            headline,
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
                              // White-tinted pill on the gradient, the
                              // LiveTripCard treatment — not the trips list's
                              // light-surface StatusPill. Flexible because
                              // the label is variable-length ("Empieza en
                              // 365 días"): a Row hands non-flex children
                              // unbounded width, so the pill's internal
                              // ellipsis only engages inside a flex slot —
                              // without it, large a11y text scales overflow
                              // the hero on narrow phones.
                              if (days != null)
                                Flexible(
                                  child: StatusPill.custom(
                                    label: l10n.upNextStartsIn(days),
                                    background:
                                        Colors.white.withValues(alpha: 0.22),
                                    foreground: Colors.white,
                                  ),
                                ),
                              if (days != null && range != null)
                                const SizedBox(width: AppSpacing.sm),
                              if (range != null)
                                Flexible(
                                  child: Text(
                                    range,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white
                                          .withValues(alpha: 0.85),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (showCitiesLine) ...[
                            const SizedBox(height: 2),
                            Text(
                              cities,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios,
                        size: 16, color: Colors.white70),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
