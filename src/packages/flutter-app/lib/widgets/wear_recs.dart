import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';
import '../utils/clothing_recs.dart';

/// The city-by-city detail inside the "What to wear & pack" sheet
/// (specs/what-to-wear): consecutive same-guidance regions fold into one row
/// ([groupWearRegions]) — a muted "Prague, Kraków · Aug 24 – Sep 1 · 15°–27°"
/// line followed by the deterministic clothing phrase.
///
/// These rows sit behind a collapsed disclosure; [PackEssentialsList] carries
/// the trip-level answer above it. The historical footnote is NOT here: it
/// qualifies the sheet header's temperature envelope too, so hiding it behind
/// the same tap would let the numbers make a forecast claim they can't back.
/// The sheet owns it (gate: [anyHistorical]).
///
/// Display-only: the trip screen builds the [WearRegionRec]s from its own
/// weather watches and passes a press-time snapshot.
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
      ],
    );
  }
}

/// The trip-level packing answer at the top of the sheet: one row per thing to
/// bring, with the stops that ask for it. Reads [packEssentials], which is the
/// union over the very groups [WearRecsList] renders below — so this list can
/// never promise something the city detail doesn't say, nor drop something it
/// does.
///
/// Read-only by design (specs/what-to-wear amendment 2026-08-17): these are a
/// derivation, the checklist under them is the traveler's own state, and
/// nothing here writes into it.
class PackEssentialsList extends StatelessWidget {
  final List<WearRegionRec> regions;

  const PackEssentialsList({super.key, required this.regions});

  /// Muted 18px leading glyph — the [CollapsibleSection] row convention.
  /// [PackEssential.rainGear] and [PackEssential.sunProtection] deliberately
  /// reuse the day chip's rain/sun glyphs (`_weatherGlyph`) so the two
  /// surfaces read as one vocabulary.
  IconData _iconFor(PackEssential e) => switch (e) {
        PackEssential.thermals => Icons.thermostat,
        PackEssential.warmCoat => Icons.ac_unit,
        PackEssential.jacket => Icons.dry_cleaning_outlined,
        PackEssential.lightLayer => Icons.layers_outlined,
        PackEssential.summerClothes => Icons.checkroom,
        PackEssential.rainGear => Icons.umbrella,
        PackEssential.sunProtection => Icons.wb_sunny,
      };

  /// Pure l10n mapping — which essentials a region earns lives in
  /// [essentialsFor], next to the band phrases these echo.
  String _labelFor(AppLocalizations l10n, PackEssential e) => switch (e) {
        PackEssential.thermals => l10n.wearPackThermals,
        PackEssential.warmCoat => l10n.wearPackWarmCoat,
        PackEssential.jacket => l10n.wearPackJacket,
        PackEssential.lightLayer => l10n.wearPackLightLayer,
        PackEssential.summerClothes => l10n.wearPackSummerClothes,
        PackEssential.rainGear => l10n.wearPackRainGear,
        PackEssential.sunProtection => l10n.wearPackSunProtection,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in packEssentials(regions))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  // Optical nudge onto the label's first line, which is
                  // taller than the glyph.
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(_iconFor(item.essential), size: 18, color: muted),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _labelFor(l10n, item.essential),
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        // Plain ', ' join — locale-safe with no conjunction,
                        // the same rule as the row labels above.
                        item.everyStop
                            ? l10n.wearEveryStop
                            : item.labels.join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
