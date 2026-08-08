import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';
import '../utils/clothing_recs.dart';

/// One region's precomputed guidance: the leg label, its date window, and the
/// derived [ClothingRec]. The trip screen builds these from its own weather
/// watches (collapsed-row summaries must be fed by the parent), so this
/// widget stays display-only.
typedef WearRegionRec = ({
  String label,
  DateTime start,
  DateTime end,
  ClothingRec rec,
});

/// The what-to-wear block at the top of the merged "What to wear & pack"
/// section (specs/what-to-wear): per region, a muted "Lisbon · Sep 15 – Sep 20
/// · 17°–28°" line followed by the deterministic clothing phrase. Historical
/// reports get the same italic "typical for these dates" qualifier as the
/// day chips — never presented as a forecast.
class WearRecsList extends StatelessWidget {
  final List<WearRegionRec> regions;

  const WearRecsList({super.key, required this.regions});

  /// Flag phrases that would restate the band's own advice are dropped:
  /// freezing/cold bands already say coat (so no "freezing nights"), cool and
  /// below already say layers (no "big day–night range"), and the hot band
  /// already says sun protection (no "very hot days").
  List<String> _phrases(AppLocalizations l10n, ClothingRec rec) {
    final band = switch (rec.band) {
      TempBand.freezing => l10n.wearBandFreezing,
      TempBand.cold => l10n.wearBandCold,
      TempBand.cool => l10n.wearBandCool,
      TempBand.mild => l10n.wearBandMild,
      TempBand.warm => l10n.wearBandWarm,
      TempBand.hot => l10n.wearBandHot,
    };
    final coldish = rec.band == TempBand.freezing || rec.band == TempBand.cold;
    return [
      band,
      if (rec.rainLikely) l10n.wearRainLikely,
      if (rec.extremeHeat && rec.band != TempBand.hot) l10n.wearExtremeHeat,
      if (rec.freezingNights && !coldish) l10n.wearFreezingNights,
      if (rec.bigSwing && !coldish && rec.band != TempBand.cool)
        l10n.wearBigSwing,
    ];
  }

  String _dateRange(DateTime start, DateTime end) {
    // DateFormat reads Intl.defaultLocale, set by the locale provider — same
    // convention as trip_format.dart.
    final fmt = DateFormat.MMMd();
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    return sameDay ? fmt.format(start) : '${fmt.format(start)} – ${fmt.format(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final region in regions)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // Spaced temp dash like the date range beside it, so a
                  // negative low never collides with the dash ("-6° – 2°").
                  '${region.label} · ${_dateRange(region.start, region.end)}'
                  ' · ${region.rec.loC}° – ${region.rec.hiC}°',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(color: muted),
                ),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: [
                      // '  ·  ' joins throughout, and the qualifier keeps the
                      // line's own size with italic+muted only — both the
                      // _weatherChip treatment.
                      TextSpan(text: _phrases(l10n, region.rec).join('  ·  ')),
                      if (region.rec.historical)
                        TextSpan(
                          text: '  ·  ${l10n.tripTypicalForDates}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: muted,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
