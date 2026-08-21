import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../providers/suggestions_provider.dart';
import '../theme/spacing.dart';
import 'destination_suggestion_card.dart';
import 'fading_edge_scroll.dart';
import 'random_suggestions.dart';
import 'section_header.dart';

/// "Somewhere new": a horizontal rail of destination photo cards over the
/// whole shuffled suggestion pool. Home shows it only when there is nothing
/// to continue (no live trip, no continue-trip card) — inspiration fills the
/// gap, but never pushes a traveler's actual trips below the fold.
///
/// A sibling of `LandingDestinationRail`, not a reuse: that rail is welded to
/// the signed-out handoff store and the landing's edge-to-edge window math.
/// Here a tap sends the prompt through Home's own signed-in path (the
/// one-tap contract every Home starter keeps), and padding belongs to the
/// hosting column.
class HomeInspirationRail extends StatelessWidget {
  /// Receives the card's prompt text — which is exactly what gets sent, the
  /// suggestion-pool contract.
  final void Function(String prompt) onPrompt;

  const HomeInspirationRail({super.key, required this.onPrompt});

  /// Matches the guides row's card width so Home's two rails share a rhythm.
  static const double _cardWidth = 230;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: context.l10n.homeInspirationTitle),
        const SizedBox(height: AppSpacing.md),
        RandomSuggestions(
          // The whole pool in a shuffled order (the rail scrolls), not the
          // chip surfaces' 3-draw sample — the count a surface shows is
          // stated by which picker it reads.
          picker: suggestionOrderProvider,
          builder: (context, prompts) => SizedBox(
            height: DestinationSuggestionCard.heightFor(
                    _cardWidth, MediaQuery.textScalerOf(context)) +
                AppSpacing.sm,
            child: ScrollConfiguration(
              // Without this a mouse cannot drag the rail on web/desktop —
              // the same reason the landing rail and photo strips set it.
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: PointerDeviceKind.values.toSet(),
              ),
              // The pool is longer than any window, so the rail always runs
              // off the edge. Without the fade it ended on a hard cut that
              // read like the last card rather than a cropped one.
              child: FadingEdgeScroll(
                builder: (context, controller) => ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  // Room below the cards so their drop shadow isn't clipped
                  // by the horizontal viewport (the guides-row rule).
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
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
                      onTap: () => onPrompt(s.text),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}
