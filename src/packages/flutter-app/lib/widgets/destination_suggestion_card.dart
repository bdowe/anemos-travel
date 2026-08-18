import 'package:flutter/material.dart';

import '../theme/spacing.dart';
import 'place_photo_card.dart'
    show kPlaceCardWidth, kPlaceCardHeight, kPlaceCardImageHeight;

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

  /// Set by [DestinationSuggestionCarousel] from the real available width.
  /// Passed in rather than read from `MediaQuery` because the cards sit inside
  /// a `PageContainer` with padding, so the window is not the space they get.
  final double width;

  const DestinationSuggestionCard({
    super.key,
    required this.prompt,
    required this.asset,
    required this.credit,
    required this.onTap,
    this.width = kPlaceCardWidth,
  });

  /// The image band scales with the card so the photo keeps its aspect; the
  /// text block does not, because two lines of `titleSmall` is what decides
  /// whether a prompt fits and that does not change with width.
  static double _imageHeightFor(double width) =>
      kPlaceCardImageHeight * (width / kPlaceCardWidth);

  /// How tall a card of [width] renders. Public because the carousel has to
  /// reserve the page height before the card exists — one derivation, so the
  /// two cannot disagree and leave the card clipped or the page padded.
  ///
  /// [textScaler] scales the text band only (the two reserved lines of
  /// titleSmall; the photo keeps its aspect regardless) — pass the ambient
  /// `MediaQuery.textScalerOf(context)` so accessibility text sizes don't
  /// clip the prompt's second line under the card's antialias clip.
  static double heightFor(double width,
          [TextScaler textScaler = TextScaler.noScaling]) =>
      _imageHeightFor(width) +
      textScaler.scale(kPlaceCardHeight - kPlaceCardImageHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageHeight = _imageHeightFor(width);

    return SizedBox(
      width: width,
      height: heightFor(width, MediaQuery.textScalerOf(context)),
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
                    // Centred, not top-aligned: the text block reserves two
                    // lines so a long prompt or a longer locale never clips,
                    // and on a carousel-width card most prompts take one —
                    // top-aligning left the title hanging over dead space.
                    child: Align(
                      alignment: Alignment.centerLeft,
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
