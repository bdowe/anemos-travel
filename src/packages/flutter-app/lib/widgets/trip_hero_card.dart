import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/money_format.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import '../utils/trip_list_insights.dart';
import 'status_pill.dart';
import 'trip_map_band.dart';

/// The one promoted-trip card, shared by the trips list's two heroes:
/// `LiveTripCard` (the trip you are ON) and `UpNextTripCard` (the one you
/// leave for next). They differ in two things — the leading date square and
/// whatever occupies the first meta slots ("Live · Day 2 of 5" vs "Starts in
/// 10 days") — so those are the parameters and everything else is this widget.
///
/// **A flat card, not a teal field** (the de-gradient pass): the standard
/// card treatment with the route band on top and the trip's name in the
/// display serif — promotion is imagery plus typography now, never a colored
/// field. The structure is the Circle next-event pattern: date square,
/// title, one "when" line, then state. The meta follows the trips list's
/// row discipline — a filled pill means STATE someone can act on (booked,
/// packed, shared, over budget); context (stays, places, cities) is a muted
/// glyph-and-label fact. The letterspaced caps eyebrow this card used to
/// open with is gone: capitals belong to the wordmark and the one place
/// eyebrow (the One Eyebrow Rule), and the state pills already name what
/// the eyebrow shouted.
///
/// **A hero REPLACES its trip's plain list card**, which is only honest while
/// it shows strictly more than that card would: this card therefore carries
/// every fact the list's `_TripCard` shows, plus the hero-only ones (the
/// cached route band, the budget figure, the pre-departure booking nudge).
/// Adding a fact to the plain card without adding it here re-opens the gap
/// that let a promoted trip lose information by being promoted.
///
/// Facts are payload-only and null/zero-hiding (the list response omits them
/// on old servers and stale offline snapshots; nothing here is derived
/// locally), so a thin trip's hero stays as small as it is today.
class TripHeroCard extends StatelessWidget {
  final Trip trip;

  /// Departure date for the leading date square (the Circle next-event
  /// anchor), or null for no square. The up-next hero passes its start date —
  /// the one fact a traveler checks a promoted trip for; the live hero passes
  /// null (its Live pill leads, and today's date is filler).
  final DateTime? leadingDate;

  /// The first slots of the meta Wrap: the hero's status pill and any label
  /// that belongs beside it. Build them with [heroPill] / [heroFact].
  final List<Widget> leadingMeta;

  final VoidCallback onTap;

  /// Whether to print the trip's duration inside the "when" line. The live
  /// hero passes false: its "Day 2 of 5" already names the total, and two
  /// totals side by side read as a contradiction waiting to happen.
  final bool showDuration;

  /// Whether to mount the cached route band. Off wherever a SECOND band for
  /// the same trip would be alive at the same time: two flutter_map instances
  /// racing for the same tile URLs cancel each other's requests
  /// (`net::ERR_ABORTED`) and BOTH end up blank, which is worse than no band.
  ///
  /// That is the live trip's situation and only the live trip's: its card is
  /// the one that renders on Home AND the trips list, and AppShell's
  /// IndexedStack keeps both alive at once. Verified A/B/A in a browser —
  /// black with Home's band mounted, satellite tiles without it, on the same
  /// trip and the same cache. So the trips list keeps the band and Home's
  /// copy goes without; the up-next hero, which exists on one surface, is
  /// unaffected.
  final bool showMap;

  const TripHeroCard({
    super.key,
    required this.trip,
    required this.leadingMeta,
    required this.onTap,
    this.leadingDate,
    this.showDuration = true,
    this.showMap = true,
  });

  /// The hero's own STATE pill ("Live", "Starts in 10 days") in the promoted
  /// register: the scheme's secondary container, the same family the rows'
  /// complete-state pills draw from. Callers build their leading pill with
  /// this so the treatment has one definition.
  static Widget heroPill(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return StatusPill.custom(
      label: label,
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
    );
  }

  /// A CONTEXT fact beside a pill ("Day 2 of 5"): muted text, the non-pill
  /// twin of [heroPill], so the meta row isn't pill soup.
  static Widget heroFact(BuildContext context, String label) => Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    final cities = citiesLabel(
      trip.cities,
      two: (a, b) => l10n.citiesTwo(a, b),
      more: (a, b, n) => l10n.citiesMore(a, b, n),
    );
    final headline = tripHeadline(trip.title, cities);
    final showCitiesLine = cities != null && headline != cities;
    // The row's own "when" register: range and duration as ONE line in the
    // second weight, exactly as the plain card prints them. 0 without both
    // dates (so an undated trip skips the span), and the duration yields to
    // the live hero's "Day 2 of 5" (see [showDuration]).
    final range = tripDateRange(trip.startDate, trip.endDate);
    final days = dayCount(trip.startDate, trip.endDate, const <int?>[]);
    final whenLine = range == null
        ? null
        : [
            range,
            if (showDuration && days > 0) l10n.tripDurationDays(days),
          ].join(' · ');
    final cityCount = trip.cities?.length ?? 0;
    final packingTotal = trip.packingTotal ?? 0;
    final stays = trip.stayTotal ?? 0;
    final places = trip.itemCount ?? 0;
    final spent = trip.budgetSpent ?? 0;
    final currency = trip.budgetCurrency ?? 'USD';
    final target = trip.budgetTarget;
    final overBudget = target != null && spent > target;
    final budgetLabel = target == null
        ? l10n.budgetSummarySpent(formatMoney(spent, currency))
        : l10n.tripsListBudgetSpentOfTarget(
            formatMoney(spent, currency), formatMoney(target, currency));
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
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    // State first, context after — the same order the plain rows use, so a
    // trip reads the same whether it is promoted or listed.
    final meta = <Widget>[
      // The hero's own status, whatever it is.
      ...leadingMeta,
      // Booking and packing progress: STATE pills in the rows' exact
      // treatment, tonal-green once complete.
      if ((trip.bookingTotal ?? 0) > 0)
        StatusPill.custom(
          label: l10n.tripsListBookedCount(
              trip.bookingBooked ?? 0, trip.bookingTotal!),
          background: trip.bookingBooked == trip.bookingTotal
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHighest,
          foreground: trip.bookingBooked == trip.bookingTotal
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      if (packingTotal > 0)
        StatusPill.custom(
          label:
              l10n.tripsListPackedCount(trip.packingDone ?? 0, packingTotal),
          background: trip.packingDone == packingTotal
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHighest,
          foreground: trip.packingDone == packingTotal
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      // Shared OUT (the owner has co-planners) — a promoted trip must not
      // lose its marker by being promoted.
      if (trip.isOwner && trip.shared == true)
        StatusPill.custom(
          label: l10n.tripsListShared,
          background: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
        ),
      // Budget rides the hero only — and its register splits by VALUE: over
      // target is a state someone should act on (a pill, the solid warning
      // pair — the alpha pair fails AA at this text size, per the brand
      // digest's recorded finding); on track is context like any other.
      if (spent > 0 && overBudget)
        StatusPill.custom(
          label: budgetLabel,
          background: AppColors.warningSolid,
          foreground: AppColors.onWarningSolid,
        ),
      // Context: what the trip HAS, which nobody acts on from this card —
      // the rows' muted glyph-and-label anatomy.
      if (spent > 0 && !overBudget)
        _Fact(icon: Icons.payments_outlined, label: budgetLabel),
      if (stays > 0)
        _Fact(
            icon: Icons.hotel_outlined,
            label: l10n.tripsListStaysCount(stays)),
      if (places > 0)
        _Fact(icon: Icons.place_outlined, label: l10n.tripsListPlaces(places)),
      if (cityCount >= 2)
        _Fact(
            icon: Icons.location_city_outlined,
            label: l10n.tripCitiesCount(cityCount)),
    ];

    return Card(
      // Zero, not the Card default 4: the hero always drew to its slot's full
      // width (the gradient Container had no margin), and the rows beneath
      // keep their inset — the promoted object being a shade wider is part of
      // the promotion.
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cached route preview; collapses to nothing on a cache miss
            // (trip never opened on this device) or an unmappable trip,
            // leaving the flat card on its own — TripMapBand's contract. It
            // absorbs its own pointers, so a tap anywhere on the band still
            // opens the trip. The Card clips the corners, so the band's own
            // clip is off.
            if (showMap)
              TripMapBand(tripId: trip.id, borderRadius: BorderRadius.zero),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (leadingDate != null) ...[
                    _DateSquare(date: leadingDate!),
                    const SizedBox(width: AppSpacing.lg),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // Real trip title, like the trips list and detail
                          // header; cities label only for legacy AI-summary
                          // titles (tripHeadline, the one shared rule). The
                          // display serif is the promotion: rows stay Inter,
                          // so the promoted trip reads promoted at a glance
                          // without a colored field doing it.
                          headline,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        if (whenLine != null)
                          Text(
                            whenLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                        if (showCitiesLine)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              cities,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
                          ),
                        if (meta.isNotEmpty)
                          Padding(
                            padding:
                                const EdgeInsets.only(top: AppSpacing.sm),
                            child: Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: meta,
                            ),
                          ),
                        // The nudge gets its own row, never a Wrap slot: one
                        // attention object per card. The solid warning pair
                        // stays — small text on the alpha pair is the brand
                        // digest's recorded AA failure.
                        if (nudgeDate != null) ...[
                          const SizedBox(height: AppSpacing.sm),
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
                        // Prose last, after the factual lines have clustered.
                        if (showSummary) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Icon(Icons.chevron_right,
                      size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Circle next-event date square: the departure day over its short month
/// inside a hairline box — the promoted trip's calendar anchor, glanceable
/// where the full range in the when-line is readable. Decoration, not a
/// control, so it has no touch-target floor.
class _DateSquare extends StatelessWidget {
  final DateTime date;

  const _DateSquare({required this.date});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = Localizations.localeOf(context).toString();
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.sm, horizontal: AppSpacing.xs),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: AppRadius.smAll,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            // Numbers are Inter, always — titleLarge carries the ladder's
            // w700 from the theme.
            '${date.day}',
            style: theme.textTheme.titleLarge,
          ),
          Text(
            // Localized short month, in whatever case the locale writes it —
            // no forced caps (capitals belong to the wordmark).
            DateFormat.MMM(locale).format(date),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A context fact on the hero: a muted glyph and a muted label, no fill —
/// the same anatomy the trips list's rows use, so a fact reads the same
/// whether its trip is promoted or listed. A filled chip on this card means
/// "state", and stays [StatusPill]'s alone.
class _Fact extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Fact({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.xs),
        // Flexible + ellipsis: a fact wider than the Wrap run it landed in
        // has nowhere to wrap to, so it truncates rather than striping the
        // card with a RenderFlex overflow.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
