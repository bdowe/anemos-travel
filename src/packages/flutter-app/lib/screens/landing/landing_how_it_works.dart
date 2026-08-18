import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/spacing.dart';
import 'landing_section_title.dart';

/// Three numbered steps: describe → get a plan → refine. A row of columns on
/// wide layouts, a column of leading-number rows below 900px.
class LandingHowItWorks extends StatelessWidget {
  const LandingHowItWorks({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final steps = [
      (n: '1', title: l10n.landingHowStep1Title, body: l10n.landingHowStep1Body),
      (n: '2', title: l10n.landingHowStep2Title, body: l10n.landingHowStep2Body),
      (n: '3', title: l10n.landingHowStep3Title, body: l10n.landingHowStep3Body),
    ];
    return Column(
      children: [
        LandingSectionTitle(title: l10n.landingHowTitle),
        const SizedBox(height: AppSpacing.xl),
        LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, s) in steps.indexed) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.xl),
                  Expanded(
                    child:
                        _HowStep(step: s, layout: _HowStepLayout.column),
                  ),
                ],
              ],
            );
          }
          return Column(
            children: [
              for (final (i, s) in steps.indexed) ...[
                if (i > 0) const SizedBox(height: AppSpacing.lg),
                _HowStep(step: s, layout: _HowStepLayout.row),
              ],
            ],
          );
        }),
      ],
    );
  }
}

enum _HowStepLayout { column, row }

class _HowStep extends StatelessWidget {
  final ({String n, String title, String body}) step;
  final _HowStepLayout layout;

  const _HowStep({required this.step, required this.layout});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final number = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.landingHairline),
      ),
      child: Text(
        step.n,
        style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
      ),
    );
    final title = Text(
      step.title,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
    final body = Text(
      step.body,
      style: theme.textTheme.bodySmall
          ?.copyWith(color: Colors.white.withValues(alpha: 0.7)),
    );

    if (layout == _HowStepLayout.column) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          number,
          const SizedBox(height: AppSpacing.md),
          title,
          const SizedBox(height: AppSpacing.xs),
          body,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        number,
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(height: AppSpacing.xs),
              body,
            ],
          ),
        ),
      ],
    );
  }
}
