import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/spacing.dart';
import '../../widgets/legal_links.dart';

/// Footer: legal links + company line, so the policy pages are reachable
/// before sign-up (affiliate programs require a discoverable privacy policy).
class LandingFooter extends StatelessWidget {
  const LandingFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          children: [
            // Shared legal strings + open helpers from legal_links.dart, so
            // the footer and the auth screen can never drift apart.
            TextButton(
              onPressed: openPrivacyPolicy,
              child: Text(l10n.legalPrivacyPolicy),
            ),
            Text('·', style: muted),
            TextButton(
              onPressed: openTermsOfService,
              child: Text(l10n.legalTermsOfService),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(l10n.landingCopyright, style: muted),
      ],
    );
  }
}
