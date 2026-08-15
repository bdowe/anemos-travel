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

/// The one promoted-trip card, shared by the trips list's two heroes:
/// `LiveTripCard` (the trip you are ON) and `UpNextTripCard` (the one you
/// leave for next). They differ in three things — the eyebrow, the leading
/// icon, and whatever occupies the first meta slot ("Live · Day 2 of 5" vs
/// "Starts in 10 days") — so those are the parameters and everything else is
/// this widget.
///
/// **A hero REPLACES its trip's plain list card**, which is only honest while
/// it shows strictly more than that card would: this Wrap therefore carries
/// every fact the list's `_TripCard` shows, plus the hero-only ones (the
/// cached route band, the budget pill, the pre-departure booking nudge).
/// Adding a fact to the plain card without adding it here re-opens the gap
/// that let a promoted trip lose information by being promoted.
///
/// Facts are payload-only and null/zero-hiding (the list response omits them
/// on old servers and stale offline snapshots; nothing here is derived
/// locally), so a thin trip's hero stays as small as it is today.
class TripHeroCard extends StatelessWidget {
  final Trip trip;

  /// Small caps label above the title ("HAPPENING NOW" / "UP NEXT").
  final String eyebrow;

  /// Glyph in the circle at the card's leading edge.
  final IconData icon;

  /// The first slots of the meta Wrap: the hero's status pill and any label
  /// that belongs beside it. Build them with [heroPill] / [heroFact].
  final List<Widget> leadingMeta;

  final VoidCallback onTap;

  /// Whether to print the trip's "N days" span. The live hero passes false:
  /// its "Day 2 of 5" already names the total, and two totals side by side
  /// read as a contradiction waiting to happen.
  final bool showDuration;

  const TripHeroCard({
    super.key,
    required this.trip,
    required this.eyebrow,
    required this.icon,
    required this.leadingMeta,
    required this.onTap,
    this.showDuration = true,
  });

  /// A STATE pill in the gradient card's treatment: white-tinted so it sits ON
  /// the gradient, unlike the trips list's light-surface [StatusPill]. Callers
  /// build their leading pill with this so the treatment has one definition.
  static Widget heroPill(String label) => StatusPill.custom(
        label: label,
        background: Colors.white.withValues(alpha: 0.22),
        foreground: Colors.white,
      );

  /// A CONTEXT fact (ranges, counts) on the gradient: plain text, the non-pill
  /// twin of [heroPill], so the meta row isn't pill soup.
  static Widget heroFact(BuildContext context, String label) => Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
            ),
      );

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
    final range = tripDateRange(trip.startDate, trip.endDate);
    // Same payload-only facts the plain card prints, read the same way: 0
    // without both dates (so an undated trip skips the span), and a "1 city"
    // label is noise when the headline or the cities line already names it.
    final days = dayCount(trip.startDate, trip.endDate, const <int?>[]);
    final cityCount = trip.cities?.length ?? 0;
    final packingTotal = trip.packingTotal ?? 0;
    final stays = trip.stayTotal ?? 0;
    final places = trip.itemCount ?? 0;
    final spent = trip.budgetSpent ?? 0;
    final currency = trip.budgetCurrency ?? 'USD';
    final target = trip.budgetTarget;
    // The nudge is PRE-DEPARTURE copy — "first leg departs {date}" — and
    // bookingNudgeDate only gates on the departure being unbooked and within
    // the window, which an unbooked RETURN leg passes on day 2 of the trip.
    // So it is silenced once the trip is under way rather than shipped saying
    // something false. It was never on the plain card being replaced, so
    // nothing is lost by the card the hero stands in for.
    final now = DateTime.now();
    final nudgeDate = tripHasStarted(trip.startDate, trip.endDate, now)
        ? null
        : bookingNudgeDate(trip, now);
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
              // contract. It absorbs its own pointers, so a tap anywhere on
              // the band still opens the trip.
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
                      child: Icon(icon, color: Colors.white, size: 26),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            eyebrow,
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
                            // titles (tripHeadline, the one shared rule).
                            headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          // A Wrap, not a Row: variable-length labels as
                          // loose-flex Row children would each be capped at an
                          // equal share of the free width and ALL ellipsize on
                          // phones (es strings run long). Wrapping to further
                          // runs keeps every label whole; a single over-wide
                          // label still ellipsizes via StatusPill's internal
                          // Flexible (the flight_offer_card pattern).
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              // The hero's own status, whatever it is.
                              ...leadingMeta,
                              if (range != null) heroFact(context, range),
                              if (showDuration && days > 0)
                                heroFact(context, l10n.tripDurationDays(days)),
                              if (cityCount >= 2)
                                heroFact(
                                    context, l10n.tripCitiesCount(cityCount)),
                              // Booking and packing progress: STATE, so pills.
                              if ((trip.bookingTotal ?? 0) > 0)
                                heroPill(l10n.tripsListBookedCount(
                                    trip.bookingBooked ?? 0,
                                    trip.bookingTotal!)),
                              if (packingTotal > 0)
                                heroPill(l10n.tripsListPackedCount(
                                    trip.packingDone ?? 0, packingTotal)),
                              // Stays and places are context, not progress:
                              // the booking pill already carries "how much is
                              // booked", so a second progress pill would
                              // double-count.
                              if (stays > 0)
                                heroFact(
                                    context, l10n.tripsListStaysCount(stays)),
                              // Shared OUT (the owner has co-planners) — a
                              // promoted trip must not lose its marker by
                              // being promoted.
                              if (trip.isOwner && trip.shared == true)
                                heroPill(l10n.tripsListShared),
                              if (places > 0)
                                heroFact(
                                    context, l10n.tripsListPlaces(places)),
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
                          // attention object per card, and the status pill
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
