import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../widgets/brand_logo.dart';

/// Branded boot splash shown while the stored session is being restored.
///
/// Pixel-matched to the static HTML splash in web/index.html — same gradient,
/// mark geometry (96px bare light mark, no plate, centre 24px above viewport
/// centre), pulse (1.0→1.04 over 1.8s), wordmark (centre 60px below viewport
/// centre) and loading dots (three 6px dots at 12px gaps, 48px + safe inset
/// off the bottom edge, opacity 0.25→0.85 staggered on the pulse's 1.8s
/// rhythm) — so the web handoff reads as one continuous screen. If you change
/// dimensions here, change index.html too.
///
/// The lockup rides high of centre so the mark + wordmark pair reads
/// optically centred as one unit; the loading signal lives at the bottom
/// edge, out of the brand moment, so a fast boot shows a still composition
/// and a slow one still reads deliberately alive. Both sides go still under
/// prefers-reduced-motion.
///
/// The native mobile splash stays mark-only: flutter_native_splash cannot
/// render text, and web is the primary surface. Do not re-run its generator
/// for this.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Matches the CSS twin's prefers-reduced-motion block: the mark holds
    // still at scale 1.0 (controller value 0) instead of pulsing.
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: AppColors.brandGradient),
      // The splash is the one route with no Scaffold, so nothing above it
      // provides a Material — and MaterialApp's no-Material fallback text
      // style carries the debug-signal yellow double underline, which the
      // wordmark inherited (visible in prod for the cross-fade beat on every
      // boot; nobody ever saw this screen at rest until specs/splash-screen).
      // A transparent Material installs the real DefaultTextStyle and paints
      // nothing over the gradient.
      child: Material(
        type: MaterialType.transparency,
        // Independent Centers (not a Column) so each layer sits at an exact
        // offset from the viewport centre, matching the CSS `top:calc(50% ±
        // N)` layers.
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Transform.translate(
                offset: const Offset(0, -24),
                child: ScaleTransition(
                  scale: Tween(begin: 1.0, end: 1.04).animate(
                    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                  ),
                  // BrandLogo only sets height; the SizedBox keeps the mark
                  // 96px wide even if the PNG isn't perfectly square.
                  child: const SizedBox.square(
                    dimension: 96,
                    child: BrandLogo.markLight(size: 96),
                  ),
                ),
              ),
            ),
            // Outside the ScaleTransition on purpose: the mark pulses, the name
            // holds still.
            Center(
              child: Transform.translate(
                offset: const Offset(0, 60),
                child: const ExcludeSemantics(
                  // The gradient is the darkest surface in the app, so this is
                  // the one wordmark that names its color instead of inheriting.
                  child: BrandWordmark(
                    fontSize: 22,
                    letterSpacing: 3,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: 48 + MediaQuery.paddingOf(context).bottom,
                ),
                child: Semantics(
                  label: context.l10n.splashLoading,
                  child: const _SplashDots(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The splash's loading signal: three white dots breathing in sequence.
///
/// Geometry and timing mirror `.splash-dot` in web/index.html exactly —
/// 6px dots, 12px gaps, opacity 0.25→0.85 on an ease-in-out triangle wave
/// with a 1.8s period and a 300ms left-to-right stagger (the CSS twin's
/// negative animation-delays put it mid-wave from the first frame; so does
/// the modulo phase here). Under reduced motion the dots hold at the wave's
/// midpoint instead of animating.
class _SplashDots extends StatefulWidget {
  const _SplashDots();

  @override
  State<_SplashDots> createState() => _SplashDotsState();
}

class _SplashDotsState extends State<_SplashDots>
    with SingleTickerProviderStateMixin {
  static const double _dotSize = 6;
  static const double _dotGap = 12;
  static const double _opacityMin = 0.25;
  static const double _opacityMax = 0.85;
  static const double _stagger = 300 / 1800; // fraction of one period

  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _wave.stop();
    } else if (!_wave.isAnimating) {
      _wave.repeat();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  double _opacityFor(int i) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return (_opacityMin + _opacityMax) / 2;
    }
    // Phase-shifted triangle wave (0→1→0 per period), eased to match the
    // CSS keyframes' per-segment ease-in-out.
    final phase = (_wave.value - i * _stagger) % 1.0;
    final triangle = 1 - (2 * phase - 1).abs();
    final eased = Curves.easeInOut.transform(triangle);
    return _opacityMin + (_opacityMax - _opacityMin) * eased;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _wave,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: _dotGap),
            Opacity(
              opacity: _opacityFor(i),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(dimension: _dotSize),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
