import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
import '../theme/spacing.dart';
import 'apple_sign_in_button.dart';
import 'google_sign_in_button.dart';
import 'legal_links.dart';

/// The SSO section of the auth screen: one "or" divider above whichever
/// provider buttons the backend has configured (Google, then Apple). Renders
/// nothing when no provider is available, leaving the form unchanged.
class SsoButtons extends ConsumerWidget {
  const SsoButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final google = ref.watch(googleSsoAvailableProvider).valueOrNull == true;
    final apple = ref.watch(appleSsoAvailableProvider).valueOrNull == true;
    final theme = Theme.of(context);
    // Availability resolves one round trip after first paint; animating the
    // expansion keeps the block from popping in and yanking the form upward.
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: (!google && !apple)
          ? const SizedBox(width: double.infinity)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: AppSpacing.lg + AppSpacing.xs),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      child: Text(context.l10n.ssoDividerOr,
                          style: theme.textTheme.bodySmall),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg + AppSpacing.xs),
                if (google) const GoogleSignInButton(),
                if (google && apple) const SizedBox(height: AppSpacing.md),
                if (apple) const AppleSignInButton(),
                const SizedBox(height: AppSpacing.md),
                // Informational — the provider's own click is the agreement.
                // Email sign-up uses the blocking LegalConsentCheckbox.
                const LegalAgreementText(),
              ],
            ),
    );
  }
}
