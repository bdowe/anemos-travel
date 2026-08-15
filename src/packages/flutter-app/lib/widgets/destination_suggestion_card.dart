import 'package:flutter/material.dart';

import '../theme/spacing.dart';
import 'place_photo_card.dart'
    show kPlaceCardWidth, kPlaceCardHeight, kPlaceCardImageHeight;
import 'random_suggestions.dart' show ResolvedSuggestion;

/// The drawn suggestions as a centered wrap of photo cards, sized to the space
/// they actually get.
///
/// Full-size cards once three fit side by side; below that each takes half the
/// row, so two sit across and the third wraps. Three full-width cards stacked
/// would push the composer off a phone screen, and a horizontal rail would
/// hide picks behind a scroll the empty state gives no reason to try.
class DestinationSuggestionRow extends StatelessWidget {
  final List<ResolvedSuggestion> prompts;
  final void Function(String prompt) onSelect;

  const DestinationSuggestionRow({
    super.key,
    required this.prompts,
    required this.onSelect,
  });

  /// The card width for a row of [prompts] cards within [maxWidth].
  static double cardWidth(double maxWidth, int count) {
    final full = count * kPlaceCardWidth + (count - 1) * AppSpacing.sm;
    if (maxWidth >= full) return kPlaceCardWidth;
    return ((maxWidth - AppSpacing.sm) / 2).clamp(120.0, kPlaceCardWidth);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = cardWidth(constraints.maxWidth, prompts.length);
        return Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          alignment: WrapAlignment.center,
          children: [
            for (final p in prompts)
              DestinationSuggestionCard(
                prompt: p.text,
                asset: p.asset,
                credit: p.credit,
                width: width,
                onTap: () => onSelect(p.text),
              ),
          ],
        );
      },
    );
  }
}

/// A one-tap conversation starter rendered as a destination photo card.
///
/// Deliberately NOT a fifth `PlaceCardData` factory. That model describes live
/// search results — rating, price level, category accent, add-to-trip, a
/// network photo URL — and a suggestion uses none of them; it is a way into a
/// conversation, not a result. What the two DO share is chrome, so the
/// geometry constants come from `place_photo_card.dart` and the fallback and
/// credit-overlay idioms are the same ones proven there. (Divergence recorded
/// in specs/destination-suggestion-cards/plan.md.)
///
/// [prompt] is BOTH what the traveler reads and what gets sent — the same
/// contract the chips had. That is why it is never split into
/// place-plus-activity for layout: it wraps to two lines instead, which also
/// keeps longer locales (es: "Ruta por la Costa Amalfitana") readable.
class DestinationSuggestionCard extends StatelessWidget {
  final String prompt;
  final String asset;

  /// Photographer + license, overlaid on the image. Required by the CC BY
  /// sources; see assets/images/destinations/CREDITS.md.
  final String credit;

  final VoidCallback onTap;

  /// Set by [DestinationSuggestionRow] from the real available width. Passed
  /// in rather than read from `MediaQuery` because the cards sit inside a
  /// `PageContainer` with padding, so the window is not the space they get.
  final double width;

  const DestinationSuggestionCard({
    super.key,
    required this.prompt,
    required this.asset,
    required this.credit,
    required this.onTap,
    this.width = kPlaceCardWidth,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scale the image band with the card so the photo keeps its aspect, but
    // leave the text block a fixed height: two lines of titleSmall is what
    // decides whether a prompt fits, and that does not change with width.
    final imageHeight = kPlaceCardImageHeight * (width / kPlaceCardWidth);
    final textHeight = kPlaceCardHeight - kPlaceCardImageHeight;

    return SizedBox(
      width: width,
      height: imageHeight + textHeight,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: prompt,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: imageHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _photo(context),
                      // Photographer credit. A Stack sibling of the image so
                      // it shows over the fallback too — the attribution path
                      // stays unconditional, as on PlacePhotoCard.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.xs, vertical: 2),
                          color: Colors.black.withValues(alpha: 0.45),
                          child: Text(
                            credit,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 9,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _photo(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: scheme.primary.withValues(alpha: 0.12),
      child: Icon(Icons.photo_outlined, size: 28, color: scheme.primary),
    );
    return Image.asset(
      asset,
      fit: BoxFit.cover,
      excludeFromSemantics: true,
      // Bound the decode to the slot; the WebPs are cut for 3x.
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
      // Fade in rather than pop, matching the landing hero.
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: child,
        );
      },
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
