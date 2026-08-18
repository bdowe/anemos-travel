import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/app_shadows.dart';
import '../theme/spacing.dart';
import '../utils/trip_days.dart';
import 'status_pill.dart';
import 'trip_map_band.dart';

/// Home's "Continue where you left off" hero: the trip to pick back up as a
/// photographic card — its own cached satellite route full-bleed under a
/// black text scrim, the title in the display face, dates and a countdown in
/// Inter beneath.
///
/// The imagery is the trip's OWN route ([TripMapBand], cache-only), never a
/// stock destination photo: a wrong photo on the wrong trip is worse than no
/// photo, and the billed /places/photo gate is not for decoration. When the
/// band has nothing to show (cache miss, unmappable trip) a flat
/// [AppColors.brandDark] field beneath carries the same text block — the one
/// surviving teal field after the de-gradient pass, because the white text
/// and its scrim need a guaranteed dark ground and this card is the app's
/// photographic hero, not its chrome.
///
/// Two scaling rules keep the overlay honest at accessibility text sizes:
/// the card's height grows by the text scaler's effect on the text band
/// (the [_textBand] portion of [baseHeight] — the
/// `DestinationSuggestionCard.heightFor` pattern), and the scrim is painted
/// on the TEXT BLOCK's own box (plus [_scrimFade] above it), not as a
/// fixed fraction of the card — so however large the text grows, it cannot
/// outrun its scrim.
class ContinueTripHero extends StatelessWidget {
  final String tripId;
  final String title;
  final String? dateRange;

  /// ISO date-only trip start. Null (unknown, or the rung-2 snapshot — see
  /// `ContinueTrip`) renders no countdown pill rather than a wrong one.
  final String? startDate;

  final VoidCallback onTap;

  /// Card height at 1.0x text scale. The text overlays the imagery, so at
  /// default scale the hero occupies exactly this much of the fold.
  static const double baseHeight = 220;

  /// The 1.0x height of the overlaid text band (two title lines + gap +
  /// meta row + bottom padding). Only this portion of the card scales with
  /// the ambient text scaler — the imagery above it does not need to grow.
  static const double _textBand = 120;

  /// How far the scrim's fade extends above the text block. Gradient
  /// geometry, not layout spacing, so it is not an [AppSpacing] value.
  static const double _scrimFade = 56;

  const ContinueTripHero({
    super.key,
    required this.tripId,
    required this.title,
    required this.dateRange,
    required this.startDate,
    required this.onTap,
  });

  /// A STATE pill on the scrim: white-tinted so it sits on imagery. This
  /// used to be `TripHeroCard.heroPill`, back when the heroes were teal
  /// fields; the flat heroes took the surface register and the over-imagery
  /// pair stayed here, where the imagery is.
  static Widget _scrimPill(String label) => StatusPill.custom(
        label: label,
        background: Colors.white.withValues(alpha: 0.22),
        foreground: Colors.white,
      );

  /// A CONTEXT fact on the scrim: plain white text, [_scrimPill]'s non-pill
  /// twin, so the meta row isn't pill soup.
  static Widget _scrimFact(BuildContext context, String label) => Text(
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
    // Sampled at build like TripHeroCard's nudge: a countdown that ages out
    // updates on the next rebuild, not spontaneously.
    final days = daysUntilTrip(startDate, DateTime.now());
    final range = (dateRange != null && dateRange!.isNotEmpty) ? dateRange : null;
    final scaler = MediaQuery.textScalerOf(context);
    final height = baseHeight + (scaler.scale(_textBand) - _textBand);

    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadius.lgAll,
        boxShadow: AppShadows.hero,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.lgAll,
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Fallback field beneath the band: shows whenever the band
              // collapses (its own contract), so the text below always sits
              // on a dark branded surface. Flat brandDark, not the retired
              // gradient — see the class doc.
              DecoratedBox(
                decoration: BoxDecoration(color: AppColors.brandDark),
              ),
              // The hero clips the whole stack at the hero radius above, so
              // the band's own corner clip is switched off — an inner
              // radius-12 clip would notch the top corners.
              TripMapBand(
                tripId: tripId,
                height: height,
                borderRadius: BorderRadius.zero,
              ),
              // One tap target over everything (the band absorbs its own
              // pointers); the text block rides inside it so the card reads
              // as a single button. The scrim is the text block's OWN
              // backdrop — bottom-anchored, full width, fading out across
              // [_scrimFade] above the text — so its coverage scales with
              // the text instead of being a fraction of the card.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          gradient: AppColors.mapScrimGradient),
                      child: SizedBox(
                        width: double.infinity,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                              _scrimFade, AppSpacing.lg, AppSpacing.lg),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                // headlineSmall = the display face via the
                                // theme; white because the scrim below it is
                                // the guaranteed dark ground.
                                style: theme.textTheme.headlineSmall
                                    ?.copyWith(color: Colors.white),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Wrap(
                                spacing: AppSpacing.sm,
                                runSpacing: AppSpacing.xs,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  // The over-IMAGERY meta register: white on
                                  // the scrim, by construction. It lives in
                                  // this file now — the flat trip heroes
                                  // moved to the surface register, and this
                                  // card is the one still setting meta on a
                                  // dark photographic ground.
                                  if (range != null) _scrimFact(context, range),
                                  if (days != null)
                                    _scrimPill(l10n.upNextStartsIn(days)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
