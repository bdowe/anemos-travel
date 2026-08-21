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
    // Teal still seeds every ROLE — primary, secondary, error, and their
    // `on` pairs — so the action colour and the brand spine are unchanged.
    // What the seed no longer decides is the CANVAS: M3 strips almost all
    // the chroma out of its neutrals, which left dark mode at #0E1513, a
    // near-black carrying a green cast too weak to read as anything but
    // grey. The surfaces now come from the wind rose's own blue instead,
    // stated as a ladder in AppColors (specs/aegean-surfaces).
    final canvas = AppColors.canvasFor(brightness);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand, // Teal theme (matches the home banner)
      brightness: brightness,
    ).copyWith(
      surface: canvas.surface,
      surfaceDim: canvas.surfaceDim,
      surfaceBright: canvas.surfaceBright,
      surfaceContainerLowest: canvas.containerLowest,
      surfaceContainerLow: canvas.containerLow,
      surfaceContainer: canvas.container,
      surfaceContainerHigh: canvas.containerHigh,
      surfaceContainerHighest: canvas.containerHighest,
      onSurface: canvas.onSurface,
      onSurfaceVariant: canvas.onSurfaceVariant,
      outline: canvas.outline,
      outlineVariant: canvas.outlineVariant,
      // The inverse pair is a SnackBar's field: it has to be the other
      // canvas, or a toast in dark mode lands on a light green-grey that
      // belongs to neither.
      inverseSurface: isDark
          ? AppColors.aegeanPaper.onSurface
          : AppColors.aegeanNight.surface,
      onInverseSurface: isDark
          ? AppColors.aegeanPaper.surface
          : AppColors.aegeanNight.onSurface,
    );

    // Inter as the app-wide UI font (Cormorant Garamond carries the wordmark
    // and the headline tier).
    final base = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      fontFamily: AppFonts.ui,
    );

    // Two registers, split at the headline/title line. Headlines carry the
    // display face (Cormorant Garamond w500, the whole tier at that one
    // weight) — the size step and the serif do the work a heavy sans used to.
    // Below that line, hierarchy is still weight, not size: titles/labels
    // carry weight, body stays regular. (M3 ships titles at w400, which reads
    // too light.)
    //
    // These are the pre-Cormorant sizes (34/30/26) × [kDisplayOpticalScale],
    // so the ladder is the SAME typography in a new face rather than a resize
    // of the app: the correction lands each tier's lowercase where the design
    // already had it. The face's x-height is 0.386 em where Marcellus's was
    // 0.500, and in sentence case the lowercase is what the eye measures.
    //
    // The previous face's own correction is what this replaces: Marcellus at
    // 0.500 em against Inter's 0.546 stepped up 2px over the M3 defaults —
    // headlineSmall at 26 landing on the Inter-bold 24 it replaced.
    //
    // Checked on screen, not derived and trusted. The first pass shipped only
    // +15%, which matched the CAPS (Cormorant's are 0.625 em to Marcellus's
    // 0.700) while the lowercase came out ~9% smaller — measured at 9.5px
    // against 11.5px on a trip's own name, which duly read recessive at the
    // top of its own page. Caps now run ahead of level instead, and that is
    // the accepted trade in a sentence-case ladder.
    final textTheme = base.textTheme.copyWith(
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontFamily: AppFonts.display,
        fontWeight: FontWeight.w500,
        fontSize: 44,
        height: 1.2,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontFamily: AppFonts.display,
        fontWeight: FontWeight.w500,
        fontSize: 39,
        height: 1.2,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontFamily: AppFonts.display,
        fontWeight: FontWeight.w500,
        fontSize: 34,
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
        // Paper reads as a recessed field in light but would glow on a dark
        // surface; dark takes the filled-field container instead. It was
        // grey[50] until the canvas went cool, at which point a warm smudge
        // sat inside every cool field.
        fillColor: isDark
            ? colorScheme.surfaceContainerHighest
            : AppColors.paperFill,
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
