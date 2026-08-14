import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../providers/api_client_provider.dart';
import '../providers/auth_provider.dart';
import '../services/connect_app_service.dart';
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
class ConnectAppScreen extends ConsumerStatefulWidget {
  final String requestToken;
  const ConnectAppScreen({super.key, required this.requestToken});

  @override
  ConsumerState<ConnectAppScreen> createState() => _ConnectAppScreenState();
}

class _ConnectAppScreenState extends ConsumerState<ConnectAppScreen> {
  ConnectAppService get _service =>
      ConnectAppService(ref.read(apiClientProvider));

  ConnectAppRequest? _request;
  bool _loading = true;
  bool _expired = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
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
      if (mounted) setState(() => (_loading = false, _expired = true));
    }
  }

  Future<void> _signIn() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
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
    final signedIn = ref.watch(authProvider).isSignedIn;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
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
