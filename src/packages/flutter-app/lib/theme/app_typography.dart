import 'package:flutter/material.dart';

/// The app's two typefaces and the three jobs they do.
///
/// Naming them here means a face swap is one edit instead of a grep, and — the
/// reason that matters more — an opt-out reads as a decision. A stat value that
/// stays in the UI face says `fontFamily: AppFonts.ui` at its call site, so the
/// next person can see it was chosen, not missed.
///
/// The families must match the `flutter.fonts` entries in `pubspec.yaml`; a
/// typo here fails silently to the platform default rather than loudly.
abstract final class AppFonts {
  /// Headings and page titles: the wordmark's own face, one weight lighter.
  ///
  /// It was Marcellus until PR #508 moved the wordmark from Cinzel to
  /// Cormorant Garamond — Marcellus was chosen as inscriptional shapes in
  /// Cinzel's register, so it outlived its reason and left a sturdy
  /// low-contrast heading sitting beside a delicate high-contrast wordmark.
  /// Matching the wordmark exactly removes the pairing question rather than
  /// re-guessing it, and takes the app from three typefaces to two.
  ///
  /// **Weight 500, and every style naming this family must say so.** The
  /// family now ships TWO real weights — 500 here, 600 for the wordmark — so
  /// an unstated weight does not fall back to the only file there is; it asks
  /// for a weight that may not exist and gets synthetic faux-bold on web,
  /// which smears a Garamond's stroke contrast. 500 rather than 400 because
  /// the app is dark-mode-first and light-on-dark optically thins these
  /// hairlines.
  static const display = 'Cormorant Garamond';

  /// Everything else — body, labels, buttons, and every number. Inter's
  /// weight ladder (400/500/600/700) is what builds hierarchy below the
  /// heading tier.
  static const ui = 'Inter';

  /// The brand wordmark. Same family as [display], one weight up (600), and
  /// kept a separate name because the wordmark is a fixed piece of artwork
  /// whose face is not a typographic choice the heading tier gets to make.
  /// Cormorant Garamond HAS a true lowercase — the wordmark's full-caps
  /// ANEMOS is produced by uppercasing the string (BrandWordmark), not by the
  /// face.
  static const wordmark = 'Cormorant Garamond';
}

/// What every display-face size was multiplied by when the face followed the
/// wordmark to Cormorant Garamond.
///
/// Not a style choice and not a re-tiering — arithmetic on the outgoing and
/// incoming faces' x-heights, which is what the eye measures in sentence case:
/// Marcellus set **0.500 em**, Cormorant Garamond sets **0.386 em**, so
/// 0.500 / 0.386 = **1.295**. Applied to every size the display face already
/// had, it lands each tier's lowercase exactly where the design had put it —
/// so this change is the same typography in a new face, not a resize of the
/// app. (Caps come out ~15% ahead of that match, because Cormorant's are
/// 0.625 em to Marcellus's 0.700; that is the accepted trade — these headings
/// are sentence case.)
///
/// **Full parity with Inter would be a different number**: 0.546 / 0.386 =
/// 1.414. The app has never been there — Marcellus at 0.500 sat 8% under
/// Inter too — and moving it is a typographic decision this pass deliberately
/// does not make.
///
/// It is named rather than folded into literals because two consumers need it
/// and one of them silently did not have it: `app_theme.dart`'s headline
/// ladder embodies it in its numbers, while [AppTextStyles.sectionHeading]
/// takes its SIZE from `titleLarge` and so has to apply it here. Leaving it
/// out is not neutral — on the first Cormorant render a trip's own name lost
/// 17% of its x-height and went recessive at the top of its page.
const double kDisplayOpticalScale = 1.295;

/// Composed styles that name a REGISTER the `textTheme` slots don't have a
/// slot for. One entry so far, and it is here because two screens reached for
/// it independently and had already drifted.
abstract final class AppTextStyles {
  /// The display face at title size — the step between a page headline and a
  /// title.
  ///
  /// A headline slot outright (26/30/34) is a PAGE title: it owns the top of a
  /// screen and sets its own rhythm. This register is for a heading that has
  /// to stay chrome — a city header that PINS while its days scroll under it,
  /// the trip's name sitting as a compact anchor over its own metadata. Both
  /// wanted "the heading face, but it must not inflate into a hero", and both
  /// said so in their own comments.
  ///
  /// Composed from two existing slots rather than written as literals:
  /// `headlineSmall` contributes the face and its explicit `w500` (the
  /// display weight — anything the family doesn't ship is faux-bold on web),
  /// `titleLarge` contributes the size. So a face swap or a scale change in
  /// `app_theme.dart` still reaches every heading in this register, and the
  /// only numbers here are the line height and the ratio below — never a size.
  ///
  /// `titleLarge` is a slot the display face BORROWS a number from, so unlike
  /// the headline slots it carries no correction of its own and has to apply
  /// [kDisplayOpticalScale] here. Leaving it out is not neutral: it sets a
  /// heading at the body face's number in a face with a much smaller
  /// x-height, which is what made a trip's own name recede at the top of its
  /// page on the first Cormorant render. 22 × 1.295 → **28**, which keeps this
  /// register the same step below `headlineSmall` (34) that 22 was below 26.
  ///
  /// Minted because it was already being spelled two ways: the itinerary's
  /// city header composed exactly this, while the trip header card arrived
  /// from the other direction (`titleLarge` + `fontFamily` + the display
  /// weight) and so
  /// carried M3's titleLarge line height instead of the headline register's
  /// 1.2. Same intent, two routes, one already-drifted property — which is
  /// the case for a token rather than a third inline composition.
  static TextStyle? sectionHeading(TextTheme textTheme) {
    final titleSize = textTheme.titleLarge?.fontSize;
    return textTheme.headlineSmall?.copyWith(
      fontSize:
          titleSize == null ? null : (titleSize * kDisplayOpticalScale).roundToDouble(),
      height: 1.2,
    );
  }
}
