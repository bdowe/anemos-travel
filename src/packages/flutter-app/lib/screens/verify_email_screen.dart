import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
import '../theme/spacing.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';

/// Deep-link email verification, reachable at /verify/<token> straight from
/// the email. Consumes the token on load (POST /auth/verify-email) and shows
/// the outcome. The API's GET link endpoint remains for old emails.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  final String token;
  const VerifyEmailScreen({super.key, required this.token});

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  bool _loading = true;

  /// Set when the token was rejected. Holds no message: the copy lives in the
  /// localizations and is picked in [build] (specs/i18n-spanish).
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _verify();
  }

  Future<void> _verify() async {
    try {
      await ref.read(authServiceProvider).verifyEmail(widget.token);
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _continue() {
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final Widget body;
    if (_loading) {
      // Deliberate loading copy — this is a deep-link landing page, so a bare
      // spinner with no words reads as a hang.
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.lg),
          Text(
            l10n.verifyChecking,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      );
    } else {
      final failed = _failed;
      // The shared outcome treatment (EmptyState), same as reset-password
      // success and SSO failure.
      body = PageContainer(
        maxWidth: 420,
        child: EmptyState(
          icon: failed ? Icons.link_off : Icons.mark_email_read_outlined,
          title: failed ? l10n.verifyLinkExpiredTitle : l10n.verifySuccessTitle,
          message: failed ? l10n.verifyLinkExpiredBody : l10n.verifySuccessBody,
          iconColor:
              failed ? theme.colorScheme.error : theme.colorScheme.primary,
          actions: [
            FilledButton(
              onPressed: _continue,
              child: Text(l10n.verifyContinue),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: GradientAppBar(title: Text(l10n.verifyTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: body,
        ),
      ),
    );
  }
}
