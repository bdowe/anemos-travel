import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
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
    if (!google && !apple) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(context.l10n.ssoDividerOr,
                  style: theme.textTheme.bodySmall),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 20),
        if (google) const GoogleSignInButton(),
        if (google && apple) const SizedBox(height: 12),
        if (apple) const AppleSignInButton(),
        const SizedBox(height: 12),
        // Informational — the provider's own click is the agreement. Email
        // sign-up uses the blocking LegalConsentCheckbox instead.
        const LegalAgreementText(),
      ],
    );
  }
}
