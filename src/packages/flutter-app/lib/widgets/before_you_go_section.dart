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
/// [kBeforeYouGoWindowDays] of departure. A trip eleven months out always has
/// open items — that is what planning is — and listing them every time Home
/// loads would turn a real pre-departure signal into wallpaper that gets
/// scrolled past. Past and undated trips never qualify. That gate now lives
/// entirely in [departingTripOf], which also decides WHICH trip this is about;
/// re-checking it here would be the same rule in two places.
///
/// **It names its trip, and it goes somewhere.** Both were missing, and each
/// made the other worse. The header said only "Before you go" over a list that
/// belonged to whichever trip [continueTripOf] had picked — so on an account
/// with two trips there was no way to tell which, and no way to find out. And
/// nothing here was tappable, on the reasoning that a row promising a fix it
/// cannot perform is the promise [HomeNextStepBand] refuses to make. True of a
/// BUTTON; the band itself is tapped end to end. So the card now carries the
/// trip's name and countdown on its first line and takes one tap into that
/// trip's health sheet — the complete list, with the buttons this surface
/// cannot host, exactly where "10 more open items" was pointing all along.
///
/// One target for the whole card, not one per row: every row would go to the
/// same sheet, so per-row taps would be five ways to say the same thing while
/// implying each row had its own destination.
///
/// The step already promoted into the band above is filtered out, so the two
/// never say the same thing twice. Everything left is capped at [_maxRows] —
/// this is a nudge toward the trip page, not a second health sheet.
///
/// Renders nothing when the review has not arrived or nothing is open — an
/// empty "Before you go" is worse than no section.
class BeforeYouGoSection extends ConsumerWidget {
  final String tripId;

  /// The trip's name, printed on the card. Required rather than optional: a
  /// readiness list that cannot say whose readiness it is describing is the
  /// defect this section was reworked to fix.
  final String tripTitle;

  /// ISO date-only trip start, for the countdown beside the name. Null only
  /// where the trip genuinely has no start date on hand, which drops the
  /// countdown and keeps the name.
  final String? startDate;

  /// Where the card goes: that trip's Trip Health sheet
  /// ([openTripHealthOnTripsTab]).
  final VoidCallback onTap;

  const BeforeYouGoSection({
    super.key,
    required this.tripId,
    required this.tripTitle,
    required this.startDate,
    required this.onTap,
  });

  static const int _maxRows = 5;

  static const _categoryIcons = <String, IconData>{
    'dates': Icons.event_outlined,
    'unscheduled': Icons.schedule_outlined,
    'packing': Icons.luggage_outlined,
    'lodging': Icons.hotel_outlined,
    'transit': Icons.directions_transit_outlined,
    'budget': Icons.account_balance_wallet_outlined,
    'bookings': Icons.confirmation_number_outlined,
  };

  /// critical first, then warn, then info. Only breaks ties among the UNDATED
  /// tail — the dated rows are ordered by the trip itself (see [openItems]).
  static const _severityRank = <String, int>{
    'critical': 0,
    'warn': 1,
    'info': 2,
  };

  /// The date a finding's fix acts on, or null when it is not a leg of the
  /// journey. The two shapes the server emits carry it under different names
  /// because they mean different things — a stay's `checkIn` is the night it
  /// starts, a transport leg's `date` is "the destination hub's first day"
  /// (trip_review.go) — but both are the point in the trip where that gap
  /// sits, which is exactly what orders them.
  static String? _fixDate(TripFinding f) => f.fix?.checkIn ?? f.fix?.date;

  /// Two rows on the same date: you travel, then you sleep there. Anything
  /// else keeps its relative order.
  static int _sameDayRank(TripFinding f) => switch (f.category) {
        'transit' => 0,
        'lodging' => 1,
        _ => 2,
      };

  /// The trip's open items **in the order the trip is actually travelled** —
  /// the same walk the next-step ladder's phase 3 makes ("Book travel & stays,
  /// in itinerary order… outbound leg → stay → next leg → … → return leg",
  /// specs/next-step-cta).
  ///
  /// It is reproduced here rather than read off the server because the ladder
  /// only ever names its FIRST open slot; the walk itself lives behind
  /// `syncTodos`, which is a POST that upserts the derived checklist, so Home
  /// must not call it. Findings carry enough to rebuild the sequence: every
  /// lodging gap knows its `checkIn` and every transport gap its leg date, so
  /// sorting on that one key yields stay-in-Kraków → fly-to-Copenhagen →
  /// stay-in-Copenhagen without inventing an ordering of its own.
  ///
  /// Undated findings — packing, budget, a whole-trip warning — cannot join a
  /// chronological walk, so they fall to the tail in severity order rather
  /// than being dropped or being given a date they do not have.
  ///
  /// [promoted] is the step already showing in the band above, and exactly one
  /// row is removed for it: the one its fix names. Filtering by CATEGORY
  /// instead — which this did first — deleted every lodging gap on the trip
  /// the moment the ladder reached lodging, leaving a "Before you go" that
  /// listed nothing but transport.
  ///
  /// Pure and static so the order can be unit-tested without a harness, the
  /// way [NextStepCard] is.
  @visibleForTesting
  static List<TripFinding> openItems(List<TripFinding> findings,
      {NextStep? promoted}) {
    final rows = [
      for (final f in findings)
        if (!_isPromoted(f, promoted)) f
    ];
    rows.sort((a, b) {
      final da = _fixDate(a), db = _fixDate(b);
      if (da != null && db != null) {
        // ISO-8601 date-only strings: lexicographic IS chronological.
        final byDate = da.compareTo(db);
        if (byDate != 0) return byDate;
        return _sameDayRank(a).compareTo(_sameDayRank(b));
      }
      // A dated row is a place in the journey; an undated one is a chore.
      if (da != null) return -1;
      if (db != null) return 1;
      return (_severityRank[a.severity] ?? 2)
          .compareTo(_severityRank[b.severity] ?? 2);
    });
    return rows;
  }

  /// Whether [f] is the very gap [promoted] already names — matched on what
  /// the two fixes ACT ON, never on category. A lodging step is the same gap
  /// as a lodging finding when they book the same city on the same night; a
  /// transport step matches on the leg's endpoints.
  static bool _isPromoted(TripFinding f, NextStep? promoted) {
    final step = promoted?.fix;
    if (step == null) return false;
    if (step.action != f.fix?.action) return false;
    return switch (step.action) {
      'add_lodging' => step.city == f.fix?.city &&
          step.checkIn == f.fix?.checkIn,
      'add_transport' => step.origin == f.fix?.origin &&
          step.destination == f.fix?.destination,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final review = ref.watch(tripReviewProvider(TripReviewKey(tripId)));
    final value = review.valueOrNull;
    if (value == null) return const SizedBox.shrink();

    final rows = openItems(value.findings, promoted: value.nextStep);
    if (rows.isEmpty) return const SizedBox.shrink();

    final shown = rows.take(_maxRows).toList();
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Sampled at build like ContinueTripHero's: a countdown that ages out
    // updates on the next rebuild, not spontaneously.
    final days = daysUntilTrip(startDate, DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: l10n.homeBeforeYouGoTitle),
        const SizedBox(height: AppSpacing.md),
        Semantics(
          button: true,
          container: true,
          child: Card(
            // Rows, not tiles: DESIGN.md rules out same-size icon cards as
            // page structure and the hero-metric template, and a readiness
            // list is exactly where both are tempting.
            //
            // The ink goes INSIDE the Card rather than wrapping it, so the
            // splash is clipped to the card's own radius instead of painting
            // a rectangle over its rounded corners.
            child: InkWell(
              onTap: onTap,
              borderRadius: AppRadius.mdAll,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Column(
                  children: [
                    _TripLine(
                      title: tripTitle,
                      countdown: days == null ? null : l10n.upNextStartsIn(days),
                    ),
                    Divider(height: 1, color: theme.colorScheme.outlineVariant),
                    for (var i = 0; i < shown.length; i++)
                      _FindingRow(
                        finding: shown[i],
                        icon: _categoryIcons[shown[i].category] ??
                            Icons.info_outline,
                        showDivider: i < shown.length - 1,
                      ),
                    // Inside the card, not stranded under it. As grey text
                    // below a dead card this was the one line that named the
                    // complete list and the one place a traveler was most
                    // likely to reach for — with nothing behind it. It is now
                    // part of the target that goes there.
                    if (rows.length > shown.length) ...[
                      Divider(
                          height: 1, color: theme.colorScheme.outlineVariant),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.md),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            l10n.homeBeforeYouGoMore(
                                rows.length - shown.length),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

/// The card's first line: whose readiness this is, how long there is left, and
/// the chevron that says the whole card goes somewhere.
///
/// It carries the trip's name because the section header cannot be relied on to
/// — [ContinueChatsSection] renders any in-progress conversations between the
/// continue-trip block and this section, so the nearest thing naming a trip can
/// be scrolled well off screen even on an account with exactly one trip.
class _TripLine extends StatelessWidget {
  final String title;
  final String? countdown;

  const _TripLine({required this.title, required this.countdown});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinTouchTarget),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (countdown != null)
                    Text(
                      countdown!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // The only affordance the card gets. A button here would have to
          // name an action, and every honest name for it ("Fix these") belongs
          // to the sheet this opens — the HomeNextStepBand rule.
          Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// One open item. Carries no tap of its own — the card around it does, and it
/// goes to the health sheet where this row's fix has a working button. A tap
/// per row would be five routes to one destination.
///
/// It carries no BUTTON for the [HomeNextStepBand] reason, which is the part of
/// the original rule that still holds: applying a fix needs the trip screen's
/// mutation providers, so a "Find a stay" here could only ever navigate, and a
/// button that names an action it does not perform is a broken promise. Stating
/// the gap and inheriting the card's tap is not.
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
