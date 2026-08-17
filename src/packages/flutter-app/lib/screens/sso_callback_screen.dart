import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
import '../services/pending_connect.dart';
import '../theme/spacing.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';

/// Why the handoff didn't produce a session. Internal only — never shown or
/// sent anywhere; [SsoCallbackScreen.build] maps it to localized copy.
enum _SsoFailure { cancelled, expired }

/// Landing spot for the SSO redirect (Google or Apple), reachable at
/// /sso/<code> (specs/google-sso, specs/apple-sso). Swaps the one-time code
/// for a session on load and hands it to the auth provider; /sso/error means
/// the OAuth flow itself failed (declined consent, expired state, unverified
/// provider email).
class SsoCallbackScreen extends ConsumerStatefulWidget {
  final String code;
  const SsoCallbackScreen({super.key, required this.code});

  @override
  ConsumerState<SsoCallbackScreen> createState() => _SsoCallbackScreenState();
}

class _SsoCallbackScreenState extends ConsumerState<SsoCallbackScreen> {
  bool _loading = true;

  /// Which failure to explain, not the sentence itself: the copy is localized
  /// and resolved in [build] (specs/i18n-spanish). `_exchange` runs from
  /// `initState`, where an inherited-widget lookup isn't allowed.
  _SsoFailure? _failure;

  @override
  void initState() {
    super.initState();
    _exchange();
  }

  Future<void> _exchange() async {
    if (widget.code == 'error') {
      setState(() {
        _loading = false;
        _failure = _SsoFailure.cancelled;
      });
      return;
    }
    try {
      final res =
          await ref.read(authServiceProvider).exchangeSsoCode(widget.code);
      await ref.read(authProvider.notifier).adoptSession(res.token, res.user);
      // A connector consent request may have sent the user here to sign in
      // (specs/mcp-connector). SSO replaced the page, so the only memory of it
      // is on-device — resume it rather than stranding the user on home with
      // an authorization the server never heard a decision about.
      final pendingConnect = await const PendingConnectStore().take();
      if (mounted) {
        // AuthGate takes over: onboarding quiz for new users, app otherwise.
        Navigator.of(context).pushNamedAndRemoveUntil(
          pendingConnect == null ? '/' : '/connect/$pendingConnect',
          (route) => false,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = _SsoFailure.expired;
        });
      }
    }
  }

  void _backToSignIn() {
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final Widget body;
    if (_loading) {
      body = const CircularProgressIndicator();
    } else {
      // The shared outcome treatment (EmptyState), same as verify-email and
      // reset-password.
      body = PageContainer(
        maxWidth: 420,
        child: EmptyState(
          icon: Icons.link_off,
          title: l10n.ssoFailedTitle,
          message: switch (_failure) {
            _SsoFailure.cancelled => l10n.ssoErrorCancelled,
            _SsoFailure.expired => l10n.ssoErrorExpired,
            null => null,
          },
          iconColor: theme.colorScheme.error,
          actions: [
            FilledButton(
              onPressed: _backToSignIn,
              child: Text(l10n.ssoBackToSignIn),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: GradientAppBar(title: l10n.ssoTitle),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: body,
        ),
      ),
    );
  }
}
