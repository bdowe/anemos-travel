import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/spacing.dart';

/// Six-card grid naming only shipped capabilities (spec: the grid may never
/// promise something the product doesn't do). Cards are plain glass
/// containers, not Material `Card`s — the dark cardTheme's neutral grey fill
/// fights the teal canvas. Monochrome on purpose: the `tool*` accents are
/// paper-tuned shade600/700 values that go muddy on deep teal; if color
/// returns, the precedent is a per-brightness mapping like `AppColors.upMark`.
class LandingFeatureGrid extends StatelessWidget {
  const LandingFeatureGrid({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final features = [
      (
        icon: Icons.auto_awesome,
        title: l10n.landingFeatureChatTitle,
        description: l10n.landingFeatureChatDescription,
      ),
      (
        icon: Icons.flight_takeoff,
        title: l10n.landingFeatureFlightsTitle,
        description: l10n.landingFeatureFlightsDescription,
      ),
      (
        icon: Icons.hotel,
        title: l10n.landingFeatureStaysTitle,
        description: l10n.landingFeatureStaysDescription,
      ),
      (
        icon: Icons.local_activity,
        title: l10n.landingFeatureEventsTitle,
        description: l10n.landingFeatureEventsDescription,
      ),
      (
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.landingFeatureBudgetTitle,
        description: l10n.landingFeatureBudgetDescription,
      ),
      (
        icon: Icons.map_outlined,
        title: l10n.landingFeatureMapTitle,
        description: l10n.landingFeatureMapDescription,
      ),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final cols = w >= 900 ? 3 : (w >= 560 ? 2 : 1);
      final cardWidth = (w - (cols - 1) * AppSpacing.lg) / cols;
      return Wrap(
        spacing: AppSpacing.lg,
        runSpacing: AppSpacing.lg,
        children: [
          for (final f in features)
            SizedBox(
              width: cardWidth,
              child: _FeatureCard(
                icon: f.icon,
                title: f.title,
                description: f.description,
              ),
            ),
        ],
      );
    });
  }
}

/// Informational glass card: icon chip + title + description (non-interactive).
class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.landingCard,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: AppColors.landingHairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            description,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.white.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}
