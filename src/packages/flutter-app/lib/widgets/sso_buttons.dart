import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
import '../theme/spacing.dart';
import 'apple_sign_in_button.dart';
import 'google_sign_in_button.dart';
import 'legal_links.dart';

/// Which provider buttons the backend has configured. The two availabilities
/// are independent futures over independent requests, so this reports nothing
/// until BOTH have settled: resolving them one at a time would paint Apple
/// alone and then insert Google *above* it, sliding a button that navigates
/// the whole tab under the reader's finger.
///
/// The single place either widget below decides what is available — they must
/// agree, or the small print can outlive the buttons it refers to.
({bool google, bool apple}) _configuredProviders(WidgetRef ref) {
  final google = ref.watch(googleSsoAvailableProvider);
  final apple = ref.watch(appleSsoAvailableProvider);
  if (google.isLoading || apple.isLoading) {
    return (google: false, apple: false);
  }
  return (google: google.valueOrNull == true, apple: apple.valueOrNull == true);
}

/// The SSO section of the auth screen: whichever provider buttons are
/// configured (Google, then Apple), above the single "or" divider that
/// separates them from the email form beneath. Sits at the TOP of the auth
/// column so one-tap sign-in is the default path; the matching small print is
/// [SsoLegalAgreement], at the bottom. Renders nothing when no provider is
/// available, leaving the form exactly as it was.
class SsoButtons extends ConsumerWidget {
  const SsoButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = _configuredProviders(ref);
    final google = providers.google;
    final apple = providers.apple;
    final theme = Theme.of(context);
    // Availability resolves one round trip after first paint (unless
    // warmSsoAvailability got there first), so animate rather than pop the
    // form downward. topCenter anchors the child's top edge, which lets the
    // block wipe in downward with the buttons growing in place — bottomCenter
    // would clip from the top and slide the primary CTA out from behind the
    // title instead.
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: (!google && !apple)
          ? const SizedBox(width: double.infinity)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (google) const GoogleSignInButton(),
                if (google && apple) const SizedBox(height: AppSpacing.md),
                if (apple) const AppleSignInButton(),
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
                // Trailing, not leading: the auth column's own gap under the
                // title spaces the block from above, this one spaces it from
                // the email field below.
                const SizedBox(height: AppSpacing.lg + AppSpacing.xs),
              ],
            ),
    );
  }
}

/// The small print that belongs to [SsoButtons] — informational, because the
/// provider's own click is the agreement (email sign-up uses the blocking
/// [LegalConsentCheckbox] instead). It is a separate widget because the
/// buttons sit at the top of the auth column and this reads as the page
/// footer at the bottom; it carries the same availability gate so no provider
/// configured still means no small print.
class SsoLegalAgreement extends ConsumerWidget {
  const SsoLegalAgreement({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = _configuredProviders(ref);
    final any = providers.google || providers.apple;
    // Same curve as SsoButtons: both ends of the column settle together
    // instead of one easing while the other snaps.
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: any
          ? const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: AppSpacing.md),
                LegalAgreementText(),
              ],
            )
          : const SizedBox(width: double.infinity),
    );
  }
}
