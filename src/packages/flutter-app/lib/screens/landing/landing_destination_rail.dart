import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/suggestions_provider.dart';
import '../../theme/spacing.dart';
import '../../widgets/destination_suggestion_card.dart';
import '../../widgets/random_suggestions.dart';
import 'landing_handoff.dart';
import 'landing_layout.dart';

/// Horizontal rail of destination photo cards over the whole shuffled
/// `suggestionPool`. Tapping a card is a commitment, not a suggestion: it
/// hands the card's prompt straight to the landing handoff (unlike the hero
/// chips, which only prefill the field).
///
/// Deliberately a lazy `ListView`, not `DestinationSuggestionCarousel`: no
/// timer, no auto-advance — a marketing page section should hold still, and
/// tests should never need to outwait an animation. The next card peeking
/// past the viewport edge is the scroll affordance.
class LandingDestinationRail extends ConsumerWidget {
  const LandingDestinationRail({super.key});

  static const double _cardWidth = 260;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(builder: (context, constraints) {
      // First card aligns with the landing content column; the scroll region
      // itself runs edge-to-edge so wide displays scroll into the gutter.
      final sidePadding = math.max(
        (constraints.maxWidth - kLandingContentWidth) / 2 + AppSpacing.lg,
        AppSpacing.lg,
      );
      return RandomSuggestions(
        // The whole pool in a shuffled order, not a 3-draw sample: a rail can
        // scroll, so it shows the full range of destinations.
        picker: suggestionOrderProvider,
        builder: (context, prompts) => SizedBox(
          height: DestinationSuggestionCard.heightFor(_cardWidth),
          child: ScrollConfiguration(
            // Without this a mouse cannot drag the rail on web/desktop — the
            // same reason the destination carousel and photo strips set it.
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: PointerDeviceKind.values.toSet(),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: sidePadding),
              itemCount: prompts.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: AppSpacing.md),
              itemBuilder: (context, i) {
                final s = prompts[i];
                return DestinationSuggestionCard(
                  prompt: s.text,
                  asset: s.asset,
                  credit: s.credit,
                  width: _cardWidth,
                  onTap: () => ref.read(landingPromptHandoffProvider)(
                    context,
                    s.text,
                    // The photo slug doubles as the suggestion id — the pool
                    // ties each prompt to exactly one photo.
                    sourceId: _slugOf(s.asset),
                  ),
                );
              },
            ),
          ),
        ),
      );
    });
  }

  /// `assets/images/destinations/paris.webp` → `paris`.
  static String _slugOf(String asset) {
    final name = asset.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot == -1 ? name : name.substring(0, dot);
  }
}
