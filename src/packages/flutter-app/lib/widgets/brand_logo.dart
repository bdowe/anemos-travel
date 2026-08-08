import 'package:flutter/material.dart';
import '../theme/spacing.dart';

/// Golden Tempo Travel brand mark: a horse head inside an omega-shaped gold
/// horseshoe (the company is named for the horse whose Derby win funded it).
/// Two forms:
/// - [BrandLogo.lockup] — the full horseshoe + wordmark image, for spots with
///   horizontal room (app-bar titles).
/// - [BrandLogo.mark] — the horseshoe icon only, for tight spots (nav rail,
///   hero badge).
///
/// The artwork is black + gold on a transparent background, so it needs a light
/// surface behind it on teal app bars / dark photos. Wrap either form in
/// [BrandBadge] for that.
class BrandLogo extends StatelessWidget {
  static const String _lockupAsset = 'assets/images/golden_tempo_logo.png';
  static const String _markAsset = 'assets/images/golden_tempo_mark.png';

  final String _asset;
  final double _height;
  final bool _isLockup;

  /// Full lockup (horseshoe mark + "GOLDEN TEMPO" wordmark), sized by [height].
  const BrandLogo.lockup({super.key, double height = 36})
      : _asset = _lockupAsset,
        _height = height,
        _isLockup = true;

  /// Horseshoe mark only, rendered as a [size]×[size] square.
  const BrandLogo.mark({super.key, double size = 28})
      : _asset = _markAsset,
        _height = size,
        _isLockup = false;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      _asset,
      height: _height,
      fit: BoxFit.contain,
      semanticLabel: 'Golden Tempo Travel',
      // Degrade gracefully if the image asset fails to load: the mark falls
      // back to a "GT" monogram, the lockup to the wordmark.
      errorBuilder: (context, _, __) => _isLockup
          ? _WordmarkFallback(height: _height)
          : _MonogramFallback(size: _height),
    );
  }
}

/// "GT" monogram stand-in for the horseshoe mark when the image asset is
/// unavailable. Fills the same [size]×[size] square the icon glyph did, so
/// layout is identical either way, and uses the same black-on-light palette
/// as the artwork (it sits on a light [BrandBadge] surface).
class _MonogramFallback extends StatelessWidget {
  final double size;
  const _MonogramFallback({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Colors.black87,
        borderRadius: AppRadius.smAll,
      ),
      child: Text(
        'GT',
        style: TextStyle(
          fontFamily: 'Playfair Display',
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
        Text(
          'Golden Tempo',
          style: TextStyle(
            fontFamily: 'Playfair Display',
            fontWeight: FontWeight.w600,
            fontSize: height * 0.32,
            color: Colors.black87,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

/// A light rounded surface that lets the black/gold [BrandLogo] read on teal
/// app bars and dark hero imagery.
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
