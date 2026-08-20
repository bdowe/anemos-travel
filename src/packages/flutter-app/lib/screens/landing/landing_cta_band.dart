import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../theme/spacing.dart';

/// Closing CTA: the page's last word, set directly on the landing canvas.
/// Every other section sits bare on Midnight Harbor, so the close does too —
/// the emptiness around one display-face line and one action is the emphasis
/// (the Aman move), not a raised field. Plain sign-up entry — the
/// prompt-carrying paths live in the hero and the destination rail.
class LandingCtaBand extends StatelessWidget {
  final VoidCallback onGetStarted;
  final VoidCallback onSignIn;

  const LandingCtaBand({
    super.key,
    required this.onGetStarted,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LayoutBuilder(builder: (context, constraints) {
      // Same self-measured threshold as the hero: the section reads its own
      // box, not the window.
      final narrow = constraints.maxWidth < 600;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
        child: Column(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Text(
                l10n.landingCtaTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  // The display face ships 500 and 600; the explicit w500
                  // keeps a theme bold from asking for a weight that doesn't
                  // exist. One tier above the section titles (34) — the
                  // closing line outranks a chapter heading, stays under the
                  // hero.
                  fontFamily: AppFonts.display,
                  fontWeight: FontWeight.w500,
                  fontSize: narrow ? 39 : 44,
                  height: 1.2,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton(
              onPressed: onGetStarted,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.brandDark,
                // Intrinsic width, centered: a button sized by its label is
                // an action; edge-to-edge white is a field.
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xxl,
                  vertical: AppSpacing.lg,
                ),
                shape: const RoundedRectangleBorder(
                  borderRadius: AppRadius.mdAll,
                ),
              ),
              child: Text(
                l10n.landingGetStarted,
                // labelLarge (the button's own slot) sized up to the CTA
                // tier. Color stated outright: M3's titleMedium/labelLarge
                // carry inherit:false + onSurface, so an unstated color
                // paints the dark theme's near-white over this white button.
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.brandDark,
                    ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: onSignIn,
              style: TextButton.styleFrom(
                // The muted ink rung, not white: beside the one white button
                // the alternate path is secondary copy, and the ladder
                // already names that role.
                foregroundColor: AppColors.landingInkMuted,
              ),
              child: Text(l10n.landingHaveAccount),
            ),
          ],
        ),
      );
    });
  }
}
