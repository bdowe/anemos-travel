import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../theme/app_colors.dart';
import '../theme/app_shadows.dart';
import '../theme/spacing.dart';
import '../utils/money_format.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import '../utils/trip_list_insights.dart';
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
    final now = DateTime.now();
    final days = daysUntilTrip(trip.startDate, now);
    final range = tripDateRange(trip.startDate, trip.endDate);
    // Insight facts (specs/trips-page-insights). Null hides — list-payload
    // fields are absent on old servers and stale offline snapshots, and are
    // never derived locally. Zero hides too: a trip with nothing packed or
    // nothing spent has no progress to report yet.
    final packingTotal = trip.packingTotal ?? 0;
    final stays = trip.stayTotal ?? 0;
    final spent = trip.budgetSpent ?? 0;
    final currency = trip.budgetCurrency ?? 'USD';
    final target = trip.budgetTarget;
    final nudgeDate = bookingNudgeDate(trip, now);
    // The summary is the AI's own blurb; suppress it when it IS the title
    // (long AI titles fall back to the cities headline, which would leave the
    // same sentence printed twice).
    final summary = (trip.summary ?? '').trim();
    final showSummary = summary.isNotEmpty && summary != trip.title;

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
                          // A Wrap, not a Row: three variable-length labels
                          // (countdown, range, booking progress — es strings
                          // run long) as loose-flex Row children would each
                          // be capped at a third of the free width and ALL
                          // ellipsize on phones. Wrapping to a second run
                          // keeps every label whole; a single over-wide
                          // label still ellipsizes via StatusPill's internal
                          // Flexible (the flight_offer_card pattern).
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              // White-tinted pills on the gradient, the
                              // LiveTripCard treatment — not the trips
                              // list's light-surface StatusPill.
                              if (days != null)
                                StatusPill.custom(
                                  label: l10n.upNextStartsIn(days),
                                  background:
                                      Colors.white.withValues(alpha: 0.22),
                                  foreground: Colors.white,
                                ),
                              if (range != null)
                                Text(
                                  range,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        Colors.white.withValues(alpha: 0.85),
                                  ),
                                ),
                              // Booking progress rides the hero too — it
                              // replaced the plain card, so the promoted trip
                              // must not lose its progress pill. Null/zero
                              // hides it.
                              if ((trip.bookingTotal ?? 0) > 0)
                                StatusPill.custom(
                                  label: l10n.tripsListBookedCount(
                                      trip.bookingBooked ?? 0,
                                      trip.bookingTotal!),
                                  background:
                                      Colors.white.withValues(alpha: 0.22),
                                  foreground: Colors.white,
                                ),
                              // Packing progress — state, so a pill.
                              if (packingTotal > 0)
                                StatusPill.custom(
                                  label: l10n.tripsListPackedCount(
                                      trip.packingDone ?? 0, packingTotal),
                                  background:
                                      Colors.white.withValues(alpha: 0.22),
                                  foreground: Colors.white,
                                ),
                              // Stays are context, not progress: the booking
                              // pill already carries "how much is booked", so
                              // a second progress pill would double-count.
                              // Plain text like the date range.
                              if (stays > 0)
                                Text(
                                  l10n.tripsListStaysCount(stays),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        Colors.white.withValues(alpha: 0.85),
                                  ),
                                ),
                              // Budget rides the hero only — money is the
                              // noisiest fact and the plain rows stay lean.
                              // Over target flips to the OPAQUE warning pair:
                              // alpha containers wash out on the gradient.
                              if (spent > 0)
                                StatusPill.custom(
                                  label: target == null
                                      ? l10n.budgetSummarySpent(
                                          formatMoney(spent, currency))
                                      : l10n.tripsListBudgetSpentOfTarget(
                                          formatMoney(spent, currency),
                                          formatMoney(target, currency)),
                                  background: target != null && spent > target
                                      ? AppColors.warningSolid
                                      : Colors.white.withValues(alpha: 0.22),
                                  foreground: target != null && spent > target
                                      ? AppColors.onWarningSolid
                                      : Colors.white,
                                ),
                            ],
                          ),
                          // The nudge gets its own row, never a Wrap slot: one
                          // attention object per card, and the countdown pill
                          // keeps the first slot it has always had.
                          if (nudgeDate != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm,
                                    vertical: AppSpacing.xs + 2),
                                decoration: BoxDecoration(
                                  color: AppColors.warningSolid,
                                  borderRadius: AppRadius.smAll,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.airplane_ticket_outlined,
                                        size: 14,
                                        color: AppColors.onWarningSolid),
                                    const SizedBox(width: AppSpacing.xs),
                                    Flexible(
                                      child: Text(
                                        // Rendered from the SAME date the
                                        // window gate returned, so the nudge
                                        // can never name a date it didn't
                                        // qualify on.
                                        l10n.tripsListBookTransportNudge(
                                            shortDateOf(nudgeDate)),
                                        // Two lines, not one: the date is the
                                        // whole point of the nudge, and it
                                        // sits at the END of the sentence —
                                        // a single line ellipsizes exactly
                                        // the fact being delivered on phones.
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: AppColors.onWarningSolid,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
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
                          // Prose last, after the factual lines have clustered.
                          if (showSummary) ...[
                            const SizedBox(height: 2),
                            Text(
                              summary,
                              maxLines: 2,
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
