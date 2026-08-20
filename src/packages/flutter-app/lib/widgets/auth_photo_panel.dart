import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../theme/spacing.dart';

/// The auth family's photo composition (specs/auth-redesign): shared by the
/// sign-in screen and the deep-link siblings (reset-password, verify-email)
/// so the numbers and the photo stack have exactly one home.
///
/// The landing family's established wide switch: at 900px and up the photo
/// becomes a full-height pane beside the form.
const double kAuthWideBreakpoint = 900;

/// Below the wide switch, the photo band appears only when the measured box
/// is at least this tall, so small phones and keyboard-up viewports keep the
/// pre-photo layout with the form fully in reach.
const double kAuthBandMinViewportHeight = 620;

/// The form pane's clamp on wide layouts. The floor is the 420px auth column
/// plus its two xl gutters, so the column never compresses; the cap keeps the
/// photograph dominant on ultrawide windows.
const double _kFormPaneMinWidth = 468;
const double _kFormPaneMaxWidth = 560;

/// The band takes 22% of the measured box within these bounds: enough photo
/// to set the scene, never enough to bury the fields.
const double _kBandMinHeight = 140;
const double _kBandMaxHeight = 220;

/// The one derivation of the wide layout's form-pane width — 45% of the
/// window, the split-pane proportion of the field.
double authFormPaneWidth(double maxWidth) =>
    (maxWidth * 0.45).clamp(_kFormPaneMinWidth, _kFormPaneMaxWidth);

/// The one derivation of the narrow layout's band height.
double authBandHeight(double maxHeight) =>
    (maxHeight * 0.22).clamp(_kBandMinHeight, _kBandMaxHeight);

/// The destination photograph that gives the auth family its atmosphere: a
/// full-height pane on wide layouts, a pinned top band on narrow ones.
/// The landing hero's photo stack — gradient fallback, cover photo,
/// heroScrim — without a logo: the form column (or the bar above) already
/// carries the brand, and the landing hero records why a surface brands
/// only once.
class AuthPhotoPanel extends StatelessWidget {
  /// Pane vs band — decides the tagline's scale and padding.
  final bool wide;

  const AuthPhotoPanel({super.key, required this.wide});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // Branded gradient behind the photo: visible until the image
          // decodes and whenever it fails to load, so the scrim and the
          // tagline always sit on a dark branded surface.
          DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.brandGradient),
          ),
          Image.asset(
            'assets/images/hero_santorini.jpg',
            fit: BoxFit.cover,
            // Decorative — the form column carries the screen's meaning.
            excludeFromSemantics: true,
            // Bound the decode to the panel, not the window: on wide
            // layouts this pane is roughly half the window. Quantized to
            // 320px buckets so a continuous resize reuses the cached
            // decode instead of minting one per pixel of width.
            cacheWidth: math.min(
              1600,
              ((constraints.maxWidth *
                          MediaQuery.devicePixelRatioOf(context)) /
                      320)
                  .ceil() *
                  320,
            ),
            // Hold the previous frame while a new bucket decodes
            // mid-resize.
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                child: child,
              );
            },
            // The gradient underneath is the fallback.
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.heroScrim),
          ),
          // The scrim is bottomLeft-darkest — the tagline sits exactly
          // there.
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.all(wide ? AppSpacing.xl : AppSpacing.lg),
              child: Text(
                context.l10n.authTagline,
                style: TextStyle(
                  // The display face's weight is always stated (w500), or web
                  // synthesizes faux-bold. Display sizes stated locally, the
                  // landing-hero precedent: 49 suits the half-window pane, 31
                  // the band — both carrying the same optical correction the
                  // headline ladder took when the face followed the wordmark
                  // (kDisplayOpticalScale).
                  fontFamily: AppFonts.display,
                  fontWeight: FontWeight.w500,
                  fontSize: wide ? 49 : 31,
                  height: 1.15,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// The photo composition for the auth family's GRADIENT-BAR screens
/// (reset-password, verify-email): the same pane / band / nothing ladder as
/// the sign-in screen, built inside the body so the bar above stays exactly
/// what it was — the landing page is the precedent for the gradient bar
/// sitting atop the photo. The sign-in screen composes the same pieces
/// itself instead: its transparent bar's icon colors and extend-behind flag
/// depend on the layout decision, so there the LayoutBuilder must wrap the
/// whole Scaffold.
///
/// Because this measures the body box (below the bar), the band threshold
/// runs ~56px conservative next to the sign-in screen — deliberate: the
/// question the threshold answers is whether the form under the chrome
/// still breathes.
class AuthPhotoBody extends StatelessWidget {
  /// The screen's own centered scroller, laid unchanged in every branch.
  final Widget child;

  const AuthPhotoBody({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= kAuthWideBreakpoint) {
        return Row(
          children: [
            const Expanded(
              child: AuthPhotoPanel(
                key: Key('auth-photo-panel'),
                wide: true,
              ),
            ),
            SizedBox(
              width: authFormPaneWidth(constraints.maxWidth),
              child: child,
            ),
          ],
        );
      }
      if (constraints.maxHeight < kAuthBandMinViewportHeight) return child;
      return Column(
        children: [
          SizedBox(
            height: authBandHeight(constraints.maxHeight),
            child: const AuthPhotoPanel(
              key: Key('auth-photo-panel'),
              wide: false,
            ),
          ),
          Expanded(child: child),
        ],
      );
    });
  }
}
