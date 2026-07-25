import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';

/// Same-origin legal pages served by the nginx gateway at the site root
/// (`/privacy`, `/terms`) — outside the Flutter app's own base path, so they
/// are opened as absolute URLs off the current origin rather than routed
/// in-app (the same origin-derivation trick trip sharing uses).
Future<void> openLegalPage(String path) async {
  String origin;
  try {
    origin = Uri.base.origin; // http(s) platforms
  } catch (_) {
    // Non-web platform: fall back to the gateway default (PUBLIC_BASE_URL's
    // documented default), where the pages are served in dev and deploy.
    origin = 'http://localhost:3000';
  }
  final uri = Uri.tryParse('$origin$path');
  if (uri != null) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

Future<void> openPrivacyPolicy() => openLegalPage('/privacy');
Future<void> openTermsOfService() => openLegalPage('/terms');

/// The "…Terms of Service and Privacy Policy." tail shared by the informational
/// line and the consent checkbox: the two tappable links joined by the
/// localized conjunction, followed by a period. The caller supplies the leading
/// prefix span so it can read either "By signing up you agree to the …" or
/// "I agree to the …".
List<Widget> _legalLinkTail(BuildContext context, TextStyle? base) {
  final l10n = context.l10n;
  return [
    _InlineLink(
        label: l10n.legalTermsOfService, style: base, onTap: openTermsOfService),
    Text(l10n.legalAgreementConjunction, style: base),
    _InlineLink(
        label: l10n.legalPrivacyPolicy, style: base, onTap: openPrivacyPolicy),
    Text('.', style: base),
  ];
}

/// "By signing up you agree to the Terms of Service and Privacy Policy" —
/// informational small print with tappable links. Used under the SSO buttons,
/// where the provider's own click is the agreement (email sign-up uses the
/// blocking [LegalConsentCheckbox] instead).
class LegalAgreementText extends StatelessWidget {
  const LegalAgreementText({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(context.l10n.legalAgreementPrefix, style: base),
        ..._legalLinkTail(context, base),
      ],
    );
  }
}

/// Blocking affirmative-consent checkbox for email sign-up: the create-account
/// button stays disabled until this is ticked. The label ("I agree to the
/// Terms of Service and Privacy Policy") carries the same tappable links.
class LegalConsentCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const LegalConsentCheckbox(
      {super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(
          value: value,
          onChanged: (v) => onChanged(v ?? false),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(context.l10n.legalConsentCheckboxPrefix, style: base),
              ..._legalLinkTail(context, base),
            ],
          ),
        ),
      ],
    );
  }
}

class _InlineLink extends StatelessWidget {
  final String label;
  final TextStyle? style;
  final Future<void> Function() onTap;

  const _InlineLink(
      {required this.label, required this.style, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: (style ?? const TextStyle()).copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
