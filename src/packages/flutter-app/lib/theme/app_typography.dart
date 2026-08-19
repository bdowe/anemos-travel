import 'package:flutter/material.dart';

/// The app's three typefaces and what each one is for.
///
/// Naming them here means a face swap is one edit instead of a grep, and — the
/// reason that matters more — an opt-out reads as a decision. A stat value that
/// stays in the UI face says `fontFamily: AppFonts.ui` at its call site, so the
/// next person can see it was chosen, not missed.
///
/// The families must match the `flutter.fonts` entries in `pubspec.yaml`; a
/// typo here fails silently to the platform default rather than loudly.
abstract final class AppFonts {
  /// Headings and page titles. Marcellus carries Roman inscriptional
  /// letterforms — the same register as the Cormorant Garamond wordmark — but
  /// with a true lowercase, so headings can be sentence case.
  ///
  /// It ships in ONE weight (400). Every style that names this family must set
  /// `FontWeight.w400` explicitly: asking for a weight the family doesn't have
  /// gets synthetic faux-bold on web, which smears a serif's stroke contrast.
  static const display = 'Marcellus';

  /// Everything else — body, labels, buttons, and every number. Inter's
  /// weight ladder (400/500/600/700) is what builds hierarchy below the
  /// heading tier.
  static const ui = 'Inter';

  /// The brand wordmark, and nothing else. Cormorant Garamond HAS a true
  /// lowercase — the wordmark's full-caps ANEMOS is produced by uppercasing
  /// the string (BrandWordmark), not by the face.
  static const wordmark = 'Cormorant Garamond';
}

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
  /// `headlineSmall` contributes the face and its explicit `w400` (Marcellus
  /// ships in ONE weight — anything else is faux-bold on web), `titleLarge`
  /// contributes the size. So a face swap or a scale change in
  /// `app_theme.dart` still reaches every heading in this register, and no
  /// number lives here but the line height.
  ///
  /// Minted because it was already being spelled two ways: the itinerary's
  /// city header composed exactly this, while the trip header card arrived
  /// from the other direction (`titleLarge` + `fontFamily` + `w400`) and so
  /// carried M3's titleLarge line height instead of the headline register's
  /// 1.2. Same intent, two routes, one already-drifted property — which is
  /// the case for a token rather than a third inline composition.
  static TextStyle? sectionHeading(TextTheme textTheme) =>
      textTheme.headlineSmall?.copyWith(
        fontSize: textTheme.titleLarge?.fontSize,
        height: 1.2,
      );
}
