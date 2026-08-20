import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../theme/spacing.dart';

/// Centered display-face section heading for the landing page's marketing
/// register. Deliberately not the app's `SectionHeader` (left-aligned
/// utilitarian titleMedium): landing sections read as chapters, not lists.
class LandingSectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;

  const LandingSectionTitle({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            // The display face ships 500 and 600; the explicit w500 keeps a
            // theme bold from asking for a weight that doesn't exist.
            fontFamily: AppFonts.display,
            fontWeight: FontWeight.w500,
            fontSize: 34,
            height: 1.2,
            color: Colors.white,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.landingInkMuted,
            ),
          ),
        ],
      ],
    );
  }
}
