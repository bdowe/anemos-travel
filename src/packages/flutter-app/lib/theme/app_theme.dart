import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_typography.dart';
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

    // Inter as the app-wide UI font (Cormorant Garamond stays the wordmark
    // only).
    final base = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      fontFamily: AppFonts.ui,
    );

    // Two registers, split at the headline/title line. Headlines carry the
    // display face (Marcellus) at one weight — the size step and the serif do
    // the work a heavy sans used to. Below that line, hierarchy is still
    // weight, not size: titles/labels carry weight, body stays regular. (M3
    // ships titles at w400, which reads too light.)
    //
    // Marcellus has a smaller x-height than Inter (0.500 em vs 0.546), so each
    // headline steps up 2px to land on the same optical size — headlineSmall
    // at 26 measures within a hair of the Inter-bold 24 it replaces, in both
    // x-height and set width.
    final textTheme = base.textTheme.copyWith(
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontFamily: AppFonts.display,
        fontWeight: FontWeight.w400,
        fontSize: 34,
        height: 1.2,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontFamily: AppFonts.display,
        fontWeight: FontWeight.w400,
        fontSize: 30,
        height: 1.2,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontFamily: AppFonts.display,
        fontWeight: FontWeight.w400,
        fontSize: 26,
        height: 1.2,
      ),
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
        shadowColor: _raisedShadow(isDark),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
      // Menus were the one surface every call site re-declared by hand, so
      // most of them didn't and took raw M3 instead — including the trip's
      // own `⋮`, which then opened as a panel OVERLAPPING the gradient app
      // bar and inheriting its white foreground. Stated once here:
      // `under` clears the bar, and the surface/elevation/radius/shadow match
      // cardTheme so a menu reads like every other raised thing in the app.
      // Dark takes the same explicit tonal step cardTheme does, for the same
      // reason: a `surface`-colored menu floating over a `surface`-colored
      // page is a hairline border away from invisible, and the tint that
      // would otherwise separate it is deliberately off everywhere.
      //
      // Row text is the READING register, not the button one: our labelLarge
      // carries w600 for buttons, and menus inherit labelLarge by default, so
      // every row shouted equally. bodyMedium at w500 sits menu rows on the
      // Inter weight ladder below titles (hierarchy is weight, not size) and
      // leaves w600 free to mean something inside a menu — the selected
      // language, a row a widget chooses to emphasize. Disabled keeps M3's
      // onSurface-at-38% so items a consumer disables still read disabled.
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? colorScheme.surfaceContainerHigh : colorScheme.surface,
        elevation: 3,
        shadowColor: _raisedShadow(isDark),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        position: PopupMenuPosition.under,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final style = _menuRowStyle(textTheme, colorScheme);
          if (states.contains(WidgetState.disabled)) {
            return style?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.38),
            );
          }
          return style;
        }),
      ),
      // MenuAnchor menus (the Bookings view's "+ Add booking") are a second
      // menu system with its own M3 defaults — surfaceContainer fill, tonal
      // tint, 4px corners — so without this block they read as a stranger
      // next to every popup menu. Same card treatment, same row register,
      // stated once for both systems via the shared helpers above.
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            isDark ? colorScheme.surfaceContainerHigh : colorScheme.surface,
          ),
          elevation: const WidgetStatePropertyAll(3),
          shadowColor: WidgetStatePropertyAll(_raisedShadow(isDark)),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          ),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(
            _menuRowStyle(textTheme, colorScheme),
          ),
        ),
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

  /// The one shadow color every raised surface casts (cards, popup menus,
  /// MenuAnchor menus). Light is a soft 16% black; dark goes 50% because the
  /// shadow only grounds the surface there — the tonal step does the
  /// separating.
  static Color _raisedShadow(bool isDark) =>
      Colors.black.withValues(alpha: isDark ? 0.5 : 0.16);

  /// Menu-row text for BOTH menu systems (popup menus and MenuAnchor items),
  /// so the two can't drift apart: Inter at bodyMedium size, w500 — below
  /// titles on the weight ladder, above body. See popupMenuTheme's comment.
  static TextStyle? _menuRowStyle(TextTheme textTheme, ColorScheme scheme) =>
      textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      );
}
