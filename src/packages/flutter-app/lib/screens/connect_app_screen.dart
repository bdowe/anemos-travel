import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../providers/api_client_provider.dart';
import '../providers/auth_provider.dart';
import '../services/connect_app_service.dart';
import '../services/pending_connect.dart';
import '../theme/spacing.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';
import 'auth_screen.dart';

/// Consent screen for an AI connector linking an Anemos account
/// (specs/mcp-connector). ChatGPT/claude.ai send the browser here at
/// /connect/<request-token>; approving mints the authorization code and sends
/// the browser back to the AI app.
///
/// Doing consent in the app rather than a server-rendered page is deliberate:
/// the app already has sessions plus email/Google/Apple sign-in, so a
/// signed-out user can authenticate however they normally do and land right
/// back on this screen (the URL drives the route — same pattern as the
/// utility-screen deep links).
///
/// Landing here signed out is normal (the AI app sends the browser straight
/// from its own settings), so this screen hands off to sign-in itself rather
/// than rendering an approve button that cannot work. Two rules make the
/// round trip survivable:
///
///  - the request token is persisted before leaving ([PendingConnectStore]),
///    because SSO navigates the page away and returns at /sso/<code> with no
///    memory of where it started;
///  - "signed in" means [AuthState.initialized] as well, so a restoring
///    session never renders an approve button backed by a dead token.
///
/// Both were absent when a signed-out user hit this screen in production
/// 2026-08-14: the approve control they saw was really the sign-in button,
/// Google sign-in then discarded the route, and no decision ever reached the
/// server while the user believed they had approved.
class ConnectAppScreen extends ConsumerStatefulWidget {
  final String requestToken;
  const ConnectAppScreen({super.key, required this.requestToken});

  @override
  ConsumerState<ConnectAppScreen> createState() => _ConnectAppScreenState();
}

class _ConnectAppScreenState extends ConsumerState<ConnectAppScreen> {
  ConnectAppService get _service =>
      ConnectAppService(ref.read(apiClientProvider));

  static const _pending = PendingConnectStore();

  ConnectAppRequest? _request;
  bool _loading = true;
  bool _expired = false;
  bool _submitting = false;
  String? _error;

  /// The request couldn't be loaded for a reason that isn't "expired" — a
  /// transport blip or a server error. Kept separate because those are worth
  /// retrying, whereas an expired token can only be restarted from the AI app.
  bool _loadFailed = false;

  /// Whether the automatic hand-off to sign-in has already fired. Latched so
  /// that a user who backs out of sign-in gets the manual button instead of
  /// being shoved into a loop they can't escape.
  bool _promptedSignIn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final req = await _service.fetchRequest(widget.requestToken);
      if (!mounted) return;
      setState(() {
        _request = req;
        _loading = false;
      });
    } on ConnectAppExpired {
      if (mounted) setState(() => (_loading = false, _expired = true));
    } catch (_) {
      // Not "expired": saying so would send the user back to their AI app to
      // start over when a retry is what's actually needed.
      if (mounted) setState(() => (_loading = false, _loadFailed = true));
    }
  }

  /// Hands off to sign-in, remembering the request first so the browser can
  /// come back here even when SSO replaces the whole page.
  Future<void> _signIn() async {
    // Before any await, while this context is still current.
    warmSsoAvailability(context);
    _promptedSignIn = true;
    await _pending.save(widget.requestToken);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
    // Only the email/password path returns here — SSO never does, because it
    // navigated away and comes back through SsoCallbackScreen. Drop the
    // reminder so it can't redirect a later, unrelated sign-in.
    await _pending.clear();
    if (mounted) setState(() {});
  }

  Future<void> _decide(bool approve) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final url = await _service.decide(widget.requestToken, approve: approve);
      if (!mounted) return;
      // Same-tab hand-back: the AI app's callback finishes the OAuth exchange.
      // NOT trackedLaunchUrl — that opens externally, for booking links.
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
      if (mounted) setState(() => _submitting = false);
    } on ConnectAppExpired {
      if (mounted) setState(() => (_submitting = false, _expired = true));
    } on ConnectAppUnauthorized {
      // The session died between rendering and approving. Recoverable, so
      // route to sign-in rather than reporting a dead end.
      if (!mounted) return;
      setState(() => _submitting = false);
      await _signIn();
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = context.l10n.errorGeneric;
        });
      }
    }
  }

  String _scopeLabel(AppLocalizations l10n, String scope) => switch (scope) {
        'trips:write' => l10n.connectScopeTripsWrite,
        'recs:read' => l10n.connectScopeRecsRead,
        _ => scope,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final auth = ref.watch(authProvider);
    // `isSignedIn` alone is optimistic: a warm boot restores a cached user
    // before revalidating the token, so trusting it here can render an approve
    // button whose request will 401.
    final sessionResolved = auth.initialized;
    final signedIn = sessionResolved && auth.isSignedIn;

    // Signed out with a request in hand: go get a session and come straight
    // back. Fires once (see [_promptedSignIn]).
    if (sessionResolved &&
        !auth.isSignedIn &&
        !_loading &&
        !_expired &&
        !_loadFailed &&
        !_promptedSignIn) {
      _promptedSignIn = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _signIn();
      });
    }

    Widget body;
    if (_loading || !sessionResolved) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_loadFailed) {
      body = PageContainer(
        maxWidth: 420,
        child: EmptyState(
          icon: Icons.cloud_off,
          title: l10n.errorGeneric,
          iconColor: theme.colorScheme.error,
          actions: [
            FilledButton(
              onPressed: _load,
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      );
    } else if (_expired) {
      body = PageContainer(
        maxWidth: 420,
        child: EmptyState(
          icon: Icons.link_off,
          title: l10n.connectExpiredTitle,
          message: l10n.connectExpiredMessage,
          iconColor: theme.colorScheme.error,
        ),
      );
    } else {
      final req = _request!;
      body = PageContainer(
        maxWidth: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: AppSpacing.md),
            Text(
              l10n.connectTitle(req.clientName),
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            // The name is whatever the app registered — say so plainly rather
            // than implying we vetted it.
            Text(
              l10n.connectUnverifiedCaution,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(l10n.connectWillBeAbleTo,
                style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            for (final scope in req.scopes)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: Text(_scopeLabel(l10n, scope))),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            if (_error != null) ...[
              Text(_error!,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error)),
              const SizedBox(height: AppSpacing.md),
            ],
            if (!signedIn) ...[
              Text(
                l10n.connectSignInPrompt,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: _signIn,
                child: Text(l10n.connectSignInCta),
              ),
            ] else ...[
              if (_submitting) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: AppSpacing.md),
              ],
              FilledButton.icon(
                onPressed: _submitting ? null : () => _decide(true),
                icon: const Icon(Icons.check),
                label: Text(l10n.connectApprove),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: _submitting ? null : () => _decide(false),
                child: Text(l10n.connectDeny),
              ),
            ],
          ],
        ),
      );
    }

    return Scaffold(
      appBar: GradientAppBar(title: Text(l10n.connectAppBarTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: body,
        ),
      ),
    );
  }
}
