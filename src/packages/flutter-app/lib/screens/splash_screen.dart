import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../widgets/brand_logo.dart';

/// Branded boot splash shown while the stored session is being restored.
///
/// Pixel-matched to the static HTML splash in web/index.html — same gradient,
/// mark geometry (96px bare light mark, no plate), pulse (1.0→1.04 over
/// 1.8s), wordmark (centre 74px below viewport centre) and spinner position
/// (centre 124px below) — so the web handoff reads as one continuous screen.
/// If you change dimensions here, change index.html too.
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
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: AppColors.brandGradient),
      // Two independent Centers (not a Column) so the mark sits at the exact
      // viewport center, matching the CSS `top:50%/left:50%` layer.
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.04).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              // BrandLogo only sets height; the SizedBox keeps the mark 96px
              // wide even if the PNG isn't perfectly square.
              child: const SizedBox.square(
                dimension: 96,
                child: BrandLogo.markLight(size: 96),
              ),
            ),
          ),
          // Outside the ScaleTransition on purpose: the mark pulses, the name
          // holds still.
          Center(
            child: Transform.translate(
              offset: const Offset(0, 74),
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
          Center(
            child: Transform.translate(
              offset: const Offset(0, 124),
              child: const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
