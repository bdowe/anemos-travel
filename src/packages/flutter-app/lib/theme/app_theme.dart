import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'spacing.dart';

/// Central app theme. Kept in one place (out of `main.dart`) so styling is
/// enforceable rather than re-declared per screen. Light and dark are the
/// same build with `brightness` flipped; the few places the two diverge are
/// explicit `isDark` conditionals below, each with its why.
abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand, // Teal theme (matches the home banner)
      brightness: brightness,
    );

    // Inter as the app-wide UI font (Playfair stays the wordmark only).
    final base = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      fontFamily: 'Inter',
    );

    // Hierarchy through weight, not size: titles/headlines carry weight, body
    // stays regular. (M3 ships titles at w400, which reads too light.)
    final textTheme = base.textTheme.copyWith(
      headlineLarge: base.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w600),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );

    return base.copyWith(
      textTheme: textTheme,
      // Chat transcripts sit inside a SelectionArea; gpt_markdown's
      // SelectableAdapter force-unwraps DefaultSelectionStyle.selectionColor,
      // so keep this explicitly set rather than relying on Material's default.
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 2,
      ),
      // A real, downward-offset drop shadow ("light from above") instead of
      // M3's flat tonal tint, so cards read as gently raised. That shadow is
      // invisible against a dark background, so in dark an explicit tonal
      // step (surfaceContainerHigh) does the separating and the stronger
      // shadow only grounds the card. The tint stays disabled in BOTH modes:
      // separation is an explicit color choice here, never an implicit
      // function of elevation.
      cardTheme: CardThemeData(
        elevation: 3,
        color: isDark ? colorScheme.surfaceContainerHigh : null,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.5 : 0.16),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: const OutlineInputBorder(borderRadius: AppRadius.smAll),
        filled: true,
        // grey[50] reads as paper in light but would glow on a dark surface;
        // dark takes the M3 filled-field container instead.
        fillColor:
            isDark ? colorScheme.surfaceContainerHighest : Colors.grey[50],
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
      ),
      // Matches the home hero button so primary actions read the same app-wide.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
      ),
    );
  }
}
