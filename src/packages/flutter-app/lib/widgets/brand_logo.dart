import 'package:flutter/material.dart';
import '../constants/app_info.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';

/// Anemos brand mark: an 8-point wind rose (άνεμος = wind) — teal cardinal
/// points, gold intercardinals. Source SVGs live in docs/branding/; PNGs are
/// rendered by scripts/brand-render.sh. (The old horse mark retired with the
/// Golden Tempo name; the agent persona "Ferdinand" keeps the equine nod.)
/// Three forms:
/// - [BrandLogo.lockup] — the full rose + "Anemos" wordmark image. Currently
///   unused: the wordmark is live text ([BrandWordmark]) everywhere, and this
///   PNG's art sits off-centre on a square canvas, so reintroducing it hangs
///   ~7pt of dead space below the mark.
/// - [BrandLogo.mark] — the rose icon only, for tight spots (nav rail,
///   landing hero).
/// - [BrandLogo.markLight] — the reversed rose (white/teal-100 cardinals),
///   for teal fields (the boot splash).
///
/// The word itself is [BrandWordmark], not part of this class — see there.
///
/// The dark artwork is teal + gold on a transparent background. It floats
/// bare on page surfaces and scrimmed imagery (auth screen, nav rail, landing
/// hero); on gradient app bars it still needs a light plate behind it — wrap
/// in [BrandBadge] there. The splash field carries no plate: the bare
/// [BrandLogo.markLight] floats directly on the teal gradient.
class BrandLogo extends StatelessWidget {
  static const String _lockupAsset = 'assets/images/anemos_logo.png';
  static const String _markAsset = 'assets/images/anemos_mark.png';
  static const String _markLightAsset = 'assets/images/anemos_mark_light.png';

  final String _asset;
  final double _height;
  final bool _isLockup;
  final bool _isLight;

  /// Full lockup (wind-rose mark + wordmark), sized by [height].
  const BrandLogo.lockup({super.key, double height = 36})
      : _asset = _lockupAsset,
        _height = height,
        _isLockup = true,
        _isLight = false;

  /// Wind-rose mark only, rendered as a [size]×[size] square.
  const BrandLogo.mark({super.key, double size = 28})
      : _asset = _markAsset,
        _height = size,
        _isLockup = false,
        _isLight = false;

  /// Reversed wind-rose mark (white/teal-100 cardinals) for teal fields,
  /// rendered as a [size]×[size] square.
  const BrandLogo.markLight({super.key, double size = 28})
      : _asset = _markLightAsset,
        _height = size,
        _isLockup = false,
        _isLight = true;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      _asset,
      height: _height,
      fit: BoxFit.contain,
      semanticLabel: 'Anemos',
      // Degrade gracefully if the image asset fails to load: the mark falls
      // back to an "A" monogram, the lockup to the wordmark.
      errorBuilder: (context, _, __) => _isLockup
          ? _WordmarkFallback(height: _height)
          : _MonogramFallback(size: _height, light: _isLight),
    );
  }
}

/// The "Anemos" wordmark as live text, in Cinzel — the brand's one piece of
/// display type. Cinzel has no true lowercase, so the string stays
/// [AppInfo.name] and paints as small-caps ANEMOS.
///
/// This is deliberately text and not the baked [BrandLogo.lockup] PNG: it
/// recolors, scales and localizes-around cleanly, and it is the thing the
/// house app bar carries on every page (see [BrandWordmark] call sites in
/// `gradient_app_bar.dart`).
///
/// The invariants — family, weight, and the string itself — live here. The
/// tuned values are parameters because caps run wide and each surface was
/// measured separately: tracking opens up as the size grows (app bar 19/1.0,
/// landing hero 24–40/1.5).
///
/// [color] defaults to **inherited**. Every gradient app bar already sets
/// `foregroundColor: Colors.white`, so those are white for free, while the
/// neutral surfaces (auth screen) and dark mode get a readable color without
/// a hardcoded one fighting them.
class BrandWordmark extends StatelessWidget {
  /// The app-bar size, tuned in PR #391 when the wordmark moved to Cinzel.
  static const double appBarFontSize = 19;

  /// The default tracking. Caps run wide, so callers using a larger size open
  /// this up — the landing hero and the splash both do.
  static const double defaultLetterSpacing = 1.0;

  final double fontSize;
  final double letterSpacing;
  final Color? color;
  final double? height;
  final List<Shadow>? shadows;

  const BrandWordmark({
    super.key,
    this.fontSize = appBarFontSize,
    this.letterSpacing = defaultLetterSpacing,
    this.color,
    this.height,
    this.shadows,
  });

  /// The style this paints with, exposed so anything that needs to *measure*
  /// the wordmark uses the exact numbers it renders — see [widthIn].
  static TextStyle styleOf({
    double fontSize = appBarFontSize,
    double letterSpacing = defaultLetterSpacing,
    Color? color,
    double? height,
    List<Shadow>? shadows,
  }) =>
      TextStyle(
        fontFamily: 'Cinzel',
        fontWeight: FontWeight.w600,
        fontSize: fontSize,
        letterSpacing: letterSpacing,
        height: height,
        color: color,
        shadows: shadows,
      );

  /// How wide the wordmark will actually paint in [context].
  ///
  /// Measured, not assumed, because the answer moves: Cinzel may not have
  /// loaded yet (or at all — in widget tests the fallback runs ~35% wider),
  /// and the traveler's text-scale setting multiplies it. The app bar's
  /// layout ladder is arithmetic on this number, so a hardcoded width would
  /// tip a large-text user's bar into overflow — and a release build does not
  /// stripe an overflow, it silently cuts the glyphs off, which is the one
  /// thing the wordmark must never do.
  static double widthIn(
    BuildContext context, {
    double fontSize = appBarFontSize,
    double letterSpacing = defaultLetterSpacing,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: AppInfo.name,
        style: styleOf(fontSize: fontSize, letterSpacing: letterSpacing),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      AppInfo.name,
      maxLines: 1,
      softWrap: false,
      style: styleOf(
        fontSize: fontSize,
        letterSpacing: letterSpacing,
        color: color,
        height: height,
        shadows: shadows,
      ),
    );
  }
}

/// "A" monogram stand-in for the wind-rose mark when the image asset is
/// unavailable. Fills the same [size]×[size] square the icon glyph did, so
/// layout is identical either way. The dark form's black87 tile keeps it
/// readable on any page surface; the [light] form inverts to a white tile
/// with a dark glyph so it still reads on the splash's teal field.
class _MonogramFallback extends StatelessWidget {
  final double size;
  final bool light;
  const _MonogramFallback({required this.size, this.light = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: light ? Colors.white.withValues(alpha: 0.92) : Colors.black87,
        borderRadius: AppRadius.smAll,
      ),
      child: Text(
        'A',
        style: TextStyle(
          fontFamily: 'Cinzel',
          fontWeight: FontWeight.w600,
          fontSize: size * 0.42,
          height: 1,
          color: light ? AppColors.brandDark : Colors.white,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Text stand-in for the lockup when the image asset is unavailable.
class _WordmarkFallback extends StatelessWidget {
  final double height;
  const _WordmarkFallback({required this.height});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MonogramFallback(size: height),
        const SizedBox(width: AppSpacing.sm),
        BrandWordmark(
          fontSize: height * 0.32,
          letterSpacing: 0.5,
          color: Colors.black87,
        ),
      ],
    );
  }
}

/// A light rounded surface that lets the teal/gold [BrandLogo] read on flat
/// teal chrome (gradient app bars, the splash field).
class BrandBadge extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final bool circle;
  final VoidCallback? onTap;

  const BrandBadge({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(
        horizontal: AppSpacing.md, vertical: AppSpacing.sm),
    this.borderRadius = AppRadius.mdAll,
    this.circle = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : borderRadius,
      ),
      child: child,
    );
    if (onTap == null) return badge;
    // The badge surface is opaque, so the ripple mostly hides behind it —
    // the InkWell is here for the tap target, web pointer cursor, and focus
    // handling rather than the splash.
    return Semantics(
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: circle ? const CircleBorder() : null,
          borderRadius: circle ? null : borderRadius,
          child: badge,
        ),
      ),
    );
  }
}
