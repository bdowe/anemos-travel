import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';

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

/// The "…Terms of Service and Privacy Policy." tail shared by the
/// informational line and the consent checkbox: one run of rich text, so the
/// sentence wraps like a paragraph at any width. The old implementation
/// composed sibling widgets inside a `Wrap`, which floated the link boxes
/// mid-paragraph once the prefix wrapped (narrow phones, Spanish copy).
///
/// Callers own the [TapGestureRecognizer]s (span recognizers must be
/// disposed, so they live in the calling State).
List<InlineSpan> _legalLinkSpans(
  BuildContext context, {
  required TapGestureRecognizer terms,
  required TapGestureRecognizer privacy,
}) {
  final l10n = context.l10n;
  final linkStyle = TextStyle(
    color: Theme.of(context).colorScheme.primary,
    decoration: TextDecoration.underline,
    decorationColor: Theme.of(context).colorScheme.primary,
  );
  return [
    TextSpan(
        text: l10n.legalTermsOfService, style: linkStyle, recognizer: terms),
    TextSpan(text: l10n.legalAgreementConjunction),
    TextSpan(
        text: l10n.legalPrivacyPolicy, style: linkStyle, recognizer: privacy),
    const TextSpan(text: '.'),
  ];
}

/// "By signing up you agree to the Terms of Service and Privacy Policy" —
/// informational small print with tappable links. Rendered as the auth
/// screen's footer by `SsoLegalAgreement`, where the provider's own click is
/// the agreement (email sign-up uses the blocking [LegalConsentCheckbox]
/// instead).
class LegalAgreementText extends StatefulWidget {
  const LegalAgreementText({super.key});

  @override
  State<LegalAgreementText> createState() => _LegalAgreementTextState();
}

class _LegalAgreementTextState extends State<LegalAgreementText> {
  final _terms = TapGestureRecognizer()..onTap = openTermsOfService;
  final _privacy = TapGestureRecognizer()..onTap = openPrivacyPolicy;

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: context.l10n.legalAgreementPrefix),
          ..._legalLinkSpans(context, terms: _terms, privacy: _privacy),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

/// Blocking affirmative-consent checkbox for email sign-up: the create-account
/// button stays disabled until this is ticked. The whole row toggles (the
/// label is tappable, not just the box) and keeps the 48px touch minimum; the
/// inline Terms/Privacy links still open their pages — a span recognizer is
/// the deepest arena member, so it wins over the row's InkWell.
class LegalConsentCheckbox extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const LegalConsentCheckbox(
      {super.key, required this.value, required this.onChanged});

  @override
  State<LegalConsentCheckbox> createState() => _LegalConsentCheckboxState();
}

class _LegalConsentCheckboxState extends State<LegalConsentCheckbox> {
  final _terms = TapGestureRecognizer()..onTap = openTermsOfService;
  final _privacy = TapGestureRecognizer()..onTap = openPrivacyPolicy;

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return InkWell(
      borderRadius: AppRadius.smAll,
      onTap: () => widget.onChanged(!widget.value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTouchTarget),
        child: Row(
          children: [
            Checkbox(
              value: widget.value,
              onChanged: (v) => widget.onChanged(v ?? false),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: base,
                  children: [
                    TextSpan(text: context.l10n.legalConsentCheckboxPrefix),
                    ..._legalLinkSpans(context,
                        terms: _terms, privacy: _privacy),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
