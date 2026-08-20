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
    final days = daysUntilTrip(startDate, DateTime.now());
    if (days == null || days > _windowDays) return const SizedBox.shrink();

    final review = ref.watch(tripReviewProvider(TripReviewKey(tripId)));
    final value = review.valueOrNull;
    if (value == null) return const SizedBox.shrink();

    final rows = openItems(value.findings, promoted: value.nextStep);
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
