import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';
import '../utils/clothing_recs.dart';

/// The what-to-wear block at the top of the merged "What to wear & pack"
/// section (specs/what-to-wear): consecutive same-guidance regions fold into
/// one row ([groupWearRegions]) — a muted "Prague, Kraków · Aug 24 – Sep 1 ·
/// 15°–27°" line followed by the deterministic clothing phrase. When any
/// displayed region is historical, ONE italic footnote after the rows says
/// the ranges are typical rather than a forecast — the old per-row qualifier
/// read as repetition. Display-only: the trip screen builds the
/// [WearRegionRec]s from its own weather watches (collapsed-row summaries
/// must be fed by the parent).
class WearRecsList extends StatelessWidget {
  final List<WearRegionRec> regions;

  const WearRecsList({super.key, required this.regions});

  /// Band phrase plus the group's surviving advisories, in
  /// [WearAdvisory.values] order. Pure l10n mapping — the suppression rules
  /// live in [effectiveAdvisories] so the grouping fold compares exactly
  /// what renders here.
  List<String> _phrases(AppLocalizations l10n, WearGroup g) {
    final band = switch (g.band) {
      TempBand.freezing => l10n.wearBandFreezing,
      TempBand.cold => l10n.wearBandCold,
      TempBand.cool => l10n.wearBandCool,
      TempBand.mild => l10n.wearBandMild,
      TempBand.warm => l10n.wearBandWarm,
      TempBand.hot => l10n.wearBandHot,
    };
    return [
      band,
      for (final a in WearAdvisory.values)
        if (g.advisories.contains(a))
          switch (a) {
            WearAdvisory.rainLikely => l10n.wearRainLikely,
            WearAdvisory.extremeHeat => l10n.wearExtremeHeat,
            WearAdvisory.freezingNights => l10n.wearFreezingNights,
            WearAdvisory.bigSwing => l10n.wearBigSwing,
          },
    ];
  }

  String _dateRange(DateTime start, DateTime end) {
    // DateFormat reads Intl.defaultLocale, set by the locale provider — same
    // convention as trip_format.dart.
    final fmt = DateFormat.MMMd();
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    return sameDay
        ? fmt.format(start)
        : '${fmt.format(start)} – ${fmt.format(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;
    final groups = groupWearRegions(regions);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in groups)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // Plain ', ' label join — locale-safe with no conjunction.
                  // Spaced temp dash like the date range beside it, so a
                  // negative low never collides with the dash ("-6° – 2°").
                  '${g.labels.join(', ')} · ${_dateRange(g.start, g.end)}'
                  ' · ${g.loC}° – ${g.hiC}°',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(color: muted),
                ),
                const SizedBox(height: 2),
                Text(
                  _phrases(l10n, g).join('  ·  '),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        if (groups.any((g) => g.historical))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              // Italic+muted only — the _weatherChip qualifier treatment.
              l10n.wearHistoricalFootnote,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: muted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}
