import 'package:flutter/material.dart';
import '../constants/app_info.dart';
import '../theme/app_typography.dart';
import '../theme/spacing.dart';

/// Anemos brand mark: the Threaded Bezel — an 8-point sun-bronze wind rose
/// (άνεμος = wind, #D2A24C) inside a mariner's compass bezel with a tick ring,
/// crossed south-west to north-east by a straight azure route line (#236684):
/// instrument outside, journey inside. Source SVGs live in docs/branding/;
/// PNGs are rendered by scripts/brand-render.sh. (The old horse mark retired
/// with the Golden Tempo name; the agent persona "Ferdinand" keeps the equine
/// nod.)
///
/// It replaced the bare Waypoint Thread rose (kept as
/// `docs/branding/mark-thread-backup.svg`), and the reason is arithmetic
/// rather than taste: that drawing's ink filled only 76% of its square
/// artboard — the rest was the route thread's hairline tails, which antialias
/// to nothing below ~48px — so every call site here painted a mark a quarter
/// smaller than the number it passed. The bezel fills 94%. Sizes throughout
/// the app were re-derived against that when it landed; **a box size is not
/// comparable across the two drawings**, so do not port a number from git
/// history without multiplying it through.
/// Three forms:
/// - [BrandLogo.lockup] — the full rose + "Anemos" wordmark image. Currently
///   unused: the wordmark is live text ([BrandWordmark]) everywhere, and this
///   PNG's art sits off-centre on a square canvas, so reintroducing it hangs
///   ~7pt of dead space below the mark.
/// - [BrandLogo.mark] — the rose icon only, for neutral chrome and page
///   surfaces (the app bar, nav rail, auth screen).
/// - [BrandLogo.markLight] — the reversed cut (bezel ring, ticks and thread in
///   white; bronze rose unchanged), for teal fields (the boot splash — the
///   last one standing after the de-gradient pass took the app bar to
///   neutral surface).
///
/// The word itself is [BrandWordmark], not part of this class — see there.
///
/// **Plate policy, v3: the mark always floats bare.** No plate is drawn
/// anywhere in the app; the only question a surface asks is which cut of the
/// mark it needs. Neutral chrome and page surfaces (app bar, nav rail, auth
/// screen) take the dark [BrandLogo.mark]; the splash's teal field takes
/// [BrandLogo.markLight], because the dark artwork's azure bezel would sink
/// into the teal there rather than stand on it.
///
/// v2 kept a white `BrandBadge` plate on gradient app bars. v3 retired it: the
/// gradient behind it never changes with theme, so the plate was white in dark
/// mode too, where it was the brightest object on the screen — and the splash
/// had already shown (PR #390) that the reversed mark reads on this exact
/// gradient unaided. Re-litigate the policy here, not at a call site.
///
/// **The bezel ring is not a plate, and the distinction is the whole policy.**
/// A plate is opaque, drawn by the app, sits *behind* the mark, and has to
/// answer to the theme — which is exactly how v2's white badge ended up being
/// the brightest thing in dark mode. The ring is transparent-backed line work
/// inside the artwork itself: it ships in the SVG, recolors with the mark's
/// two cuts, and lets the surface show through its middle. Nothing here draws
/// a container. So this policy still forbids what it was written to forbid —
/// do not read the ring as permission to reintroduce a badge.
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

  /// Reversed wind-rose mark (white/pale-azure thread) for teal fields —
  /// the boot splash — rendered as a [size]×[size] square.
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

/// The "ANEMOS" wordmark as live text, in Cormorant Garamond SemiBold —
/// the brand's one piece of display type. The face HAS a true lowercase and
/// the approved wordmark is full caps, so the string is
/// [AppInfo.name].toUpperCase() — the caps come from the string, not (as
/// with the old Cinzel) from the face.
///
/// This is deliberately text and not the baked [BrandLogo.lockup] PNG: it
/// recolors, scales and localizes-around cleanly, and it is the thing the
/// house app bar carries on every page (see [BrandWordmark] call sites in
/// `gradient_app_bar.dart`).
///
/// The invariants — family, weight, and the string itself — live here. The
/// tuned values are parameters because caps run wide and each surface was
/// measured separately: tracking opens up as the size grows (app bar 19/1.0,
/// boot splash 22/3). Cormorant's caps run narrower than Cinzel's, so the
/// same sizes sit a touch slimmer than they used to.
///
/// [color] defaults to **inherited**. Every gradient app bar already sets
/// `foregroundColor: Colors.white`, so those are white for free, while the
/// neutral surfaces (auth screen) and dark mode get a readable color without
/// a hardcoded one fighting them.
class BrandWordmark extends StatelessWidget {
  /// The app-bar size, tuned in PR #391 when the wordmark moved to Cinzel
  /// and kept through the move to Cormorant Garamond (its caps run
  /// narrower, so no retune was needed).
  static const double appBarFontSize = 19;

  /// The default tracking. Caps run wide, so callers using a larger size open
  /// this up — the boot splash does.
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
        fontFamily: AppFonts.wordmark,
        fontWeight: FontWeight.w600,
        fontSize: fontSize,
        letterSpacing: letterSpacing,
        height: height,
        color: color,
        shadows: shadows,
      );

  /// How wide the wordmark will actually paint in [context].
  ///
  /// Measured, not assumed, because the answer moves: the face may not have
  /// loaded yet (or at all — in widget tests the fallback runs wider than
  /// Cormorant's caps), and the traveler's text-scale setting multiplies
  /// it. The app bar's
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
        text: AppInfo.name.toUpperCase(),
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
      AppInfo.name.toUpperCase(),
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
/// readable on any page surface; the [light] form is a bare white glyph — it
/// stands on a teal field, where white reads unaided and a tile would be the
/// plate the policy above retired.
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
      decoration: light
          ? null
          : const BoxDecoration(
              color: Colors.black87,
              borderRadius: AppRadius.smAll,
            ),
      child: Text(
        'A',
        style: TextStyle(
          fontFamily: AppFonts.wordmark,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.42,
          height: 1,
          color: Colors.white,
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
