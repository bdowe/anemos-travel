import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../widgets/auth_photo_panel.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';

/// Deep-link password reset, reachable at /reset/<token> straight from the
/// email. Works signed-out — the token from the URL is the credential. The
/// paste-a-code dialog flow on the auth screen remains as a fallback.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  final String token;
  const ResetPasswordScreen({super.key, required this.token});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _saving = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    // Captured before the await: the route can be popped mid-request, and an
    // inherited-widget lookup would then throw.
    final l10n = context.l10n;
    try {
      await ref
          .read(authServiceProvider)
          .resetPassword(widget.token, _passwordController.text);
      // Let the browser / password manager offer to update the saved login.
      TextInput.finishAutofillContext();
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(l10n, e);
        });
      }
    }
  }

  void _goToSignIn() {
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: GradientAppBar(title: context.l10n.resetAppBarTitle),
      // The family photo composition around the untouched column
      // (specs/auth-redesign): pane beside the form on wide, band above it
      // on tall phones, nothing on short viewports. The gradient bar stays —
      // the landing page is the precedent for it sitting atop the photo.
      body: AuthPhotoBody(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            // The auth family's shared 420px column (see auth_screen.dart).
            child: PageContainer(
              maxWidth: 420,
              child: _done ? _buildSuccess(theme) : _buildForm(theme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuccess(ThemeData theme) {
    final l10n = context.l10n;
    // The shared outcome treatment (EmptyState) so this reads identically to
    // verify-email, SSO failure, and every other terminal state in the app.
    return EmptyState(
      icon: Icons.check_circle_outline,
      title: l10n.resetSuccessTitle,
      message: l10n.resetSuccessBody,
      iconColor: theme.colorScheme.primary,
      actions: [
        FilledButton(
          onPressed: _goToSignIn,
          child: Text(l10n.resetSignInButton),
        ),
      ],
    );
  }

  Widget _buildForm(ThemeData theme) {
    final l10n = context.l10n;
    return Form(
      key: _formKey,
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.resetChooseTitle,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              // Advance to the confirm field; Enter submits from there.
              textInputAction: TextInputAction.next,
              decoration:
                  InputDecoration(labelText: l10n.resetNewPasswordLabel),
              validator: (v) {
                if ((v ?? '').isEmpty) return l10n.resetPasswordRequired;
                if (v!.length < 8) {
                  return l10n.resetPasswordTooShort;
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _confirmController,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: l10n.resetConfirmLabel),
              validator: (v) {
                if ((v ?? '').isEmpty) return l10n.resetConfirmRequired;
                if (v != _passwordController.text) {
                  return l10n.resetPasswordsMismatch;
                }
                return null;
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.lg),
              Text(
                _error!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            FilledButton(
              onPressed: _saving ? null : _submit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              ),
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.resetSetNewPassword),
            ),
          ],
        ),
      ),
    );
  }
}
