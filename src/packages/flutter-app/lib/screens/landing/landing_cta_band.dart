import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_shadows.dart';
import '../../theme/spacing.dart';
import '../../widgets/page_container.dart';

/// Closing CTA: the one intentionally lighter-teal surface on the landing
/// canvas, so the last thing the page says pops. Plain sign-up entry — the
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
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return PageContainer(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl + AppSpacing.sm),
        decoration: BoxDecoration(
          gradient: AppColors.brandGradient,
          borderRadius: AppRadius.lgAll,
          boxShadow: AppShadows.brandCard,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.landingCtaTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton(
              onPressed: onGetStarted,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.brandDark,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                shape: const RoundedRectangleBorder(
                  borderRadius: AppRadius.mdAll,
                ),
              ),
              child: Text(
                l10n.landingGetStarted,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: onSignIn,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              ),
              child: Text(l10n.landingHaveAccount),
            ),
          ],
        ),
      ),
    );
  }
}
