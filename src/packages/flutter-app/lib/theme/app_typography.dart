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
  /// letterforms — the same register as the Cinzel wordmark — but with a true
  /// lowercase, so headings can be sentence case.
  ///
  /// It ships in ONE weight (400). Every style that names this family must set
  /// `FontWeight.w400` explicitly: asking for a weight the family doesn't have
  /// gets synthetic faux-bold on web, which smears a serif's stroke contrast.
  static const display = 'Marcellus';

  /// Everything else — body, labels, buttons, and every number. Inter's
  /// weight ladder (400/500/600/700) is what builds hierarchy below the
  /// heading tier.
  static const ui = 'Inter';

  /// The brand wordmark, and nothing else. Cinzel has no true lowercase, so
  /// any text set in it paints as small caps.
  static const wordmark = 'Cinzel';
}
