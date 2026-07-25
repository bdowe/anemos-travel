import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
import '../widgets/brand_logo.dart';
import '../widgets/language_menu_button.dart';
import '../widgets/sso_buttons.dart';
import '../widgets/legal_links.dart';
import '../utils/snack.dart';

class AuthScreen extends ConsumerStatefulWidget {
  /// Whether the form opens in sign-in (true) or create-account (false) mode.
  final bool initialIsLogin;

  const AuthScreen({super.key, this.initialIsLogin = true});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();
  late bool _isLogin = widget.initialIsLogin;

  // Blocking affirmative consent for email sign-up (launch legal gate): the
  // create-account button stays disabled until this is ticked. Login and SSO
  // don't use it — SSO shows an informational line under its own buttons.
  bool _agreedToTerms = false;

  // Auto-submit after a password-manager autofill. An extension fill is
  // distinctive: each field goes from empty to its full value within one
  // rapid burst (a single change event, or keystroke-simulated characters
  // milliseconds apart), and the two fields fill within ~a second of each
  // other. A human types one field over seconds — the burst window lapses —
  // and can't complete both fields back-to-back. Each auto-submit consumes
  // the fill timestamps — a failed attempt is never retried without a
  // fresh fill gesture (keeps us clear of the server-side login lockout).
  static const _burstWindow = Duration(milliseconds: 400);
  static const _fillWindow = Duration(milliseconds: 1500);
  String _prevEmail = '';
  String _prevPassword = '';
  DateTime? _emailBurstStart;
  DateTime? _passwordBurstStart;
  DateTime? _emailFillAt;
  DateTime? _passwordFillAt;
  Timer? _autoSubmitTimer;

  @override
  void initState() {
    super.initState();
    _emailController.addListener(() => _onCredentialChanged(isEmail: true));
    _passwordController.addListener(() => _onCredentialChanged(isEmail: false));
  }

  @override
  void dispose() {
    _autoSubmitTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  void _onCredentialChanged({required bool isEmail}) {
    final value = isEmail ? _emailController.text : _passwordController.text;
    final prev = isEmail ? _prevEmail : _prevPassword;
    if (value == prev) return;
    // Any new change invalidates a pending auto-submit; _maybeAutoSubmit
    // re-arms it below only if the fill signature still holds.
    _autoSubmitTimer?.cancel();
    final now = DateTime.now();
    // The burst starts when the field first becomes non-empty; it ends (and
    // the field no longer counts as manager-filled) once changes keep
    // arriving past the burst window — that's a human typing.
    var burstStart = isEmail ? _emailBurstStart : _passwordBurstStart;
    if (value.isEmpty) {
      burstStart = null;
    } else if (prev.isEmpty) {
      burstStart = now;
    }
    final filled =
        value.isNotEmpty &&
        burstStart != null &&
        now.difference(burstStart) <= _burstWindow;
    final fillAt = filled ? now : null;
    if (isEmail) {
      _prevEmail = value;
      _emailBurstStart = burstStart;
      _emailFillAt = fillAt;
    } else {
      _prevPassword = value;
      _passwordBurstStart = burstStart;
      _passwordFillAt = fillAt;
    }
    _maybeAutoSubmit();
  }

  void _maybeAutoSubmit() {
    if (!_isLogin) return;
    final emailAt = _emailFillAt;
    final passwordAt = _passwordFillAt;
    if (emailAt == null || passwordAt == null) return;
    if (emailAt.difference(passwordAt).abs() > _fillWindow) return;
    if (ref.read(authProvider).loading) return;
    _autoSubmitTimer?.cancel();
    // Debounced past the burst window so it fires once the fill has fully
    // arrived, with the complete values in both controllers.
    _autoSubmitTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || !_isLogin) return;
      _emailFillAt = null;
      _passwordFillAt = null;
      _submit();
    });
  }

  Future<void> _submit() async {
    // Consent gate for email sign-up: also guards the Enter-key path
    // (onFieldSubmitted), which reaches here without touching the disabled
    // create-account button.
    if (!_isLogin && !_agreedToTerms) return;
    if (!_formKey.currentState!.validate()) return;
    final notifier = ref.read(authProvider.notifier);
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final ok = _isLogin
        ? await notifier.login(email, password)
        : await notifier.register(
            email,
            password,
            displayName: _displayNameController.text.trim(),
          );
    // Tell the platform the autofill session succeeded so the browser /
    // password manager offers to save the credentials.
    if (ok) TextInput.finishAutofillContext();
    // On success the AuthGate swaps the root from the landing page to the app.
    // When this screen was pushed on top of the landing page, pop it so the
    // app (now the root) is revealed instead of this form staying on top.
    if (ok && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _toggleMode() {
    setState(() => _isLogin = !_isLogin);
  }

  /// Two-step forgot-password flow: request a reset code by email, then
  /// enter the code + a new password. No URL routing needed, works on all
  /// platforms.
  Future<void> _forgotPassword() async {
    final requested = await showDialog<bool>(
      context: context,
      builder: (_) => _RequestResetDialog(
        initialEmail: _emailController.text.trim(),
        onRequest: (email) =>
            ref.read(authServiceProvider).requestPasswordReset(email),
      ),
    );
    if (requested != true || !mounted) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _EnterResetCodeDialog(
        onReset: (code, password) =>
            ref.read(authServiceProvider).resetPassword(code, password),
      ),
    );
    if (done == true && mounted) {
      showSnack(context, context.l10n.authPasswordUpdatedSnack);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final auth = ref.watch(authProvider);

    return Scaffold(
      // Transparent AppBar so the implied back arrow gives a way back to the
      // landing page underneath (this screen is always pushed on top of it).
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: const [LanguageMenuButton()],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              // AutofillGroup makes Flutter web expose the fields as a DOM
              // <form> with autocomplete attributes, which is what browser
              // password managers (1Password etc.) hook into.
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const BrandLogo.mark(size: 72),
                    const SizedBox(height: 16),
                    Text(
                      _isLogin
                          ? l10n.authWelcomeBack
                          : l10n.authCreateAccountTitle,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [
                        AutofillHints.username,
                        AutofillHints.email,
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.authEmailLabel,
                      ),
                      validator: (v) {
                        final value = (v ?? '').trim();
                        if (value.isEmpty) return l10n.authEmailRequired;
                        if (!value.contains('@') || !value.contains('.')) {
                          return l10n.authEmailInvalid;
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: [
                        _isLogin
                            ? AutofillHints.password
                            : AutofillHints.newPassword,
                      ],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.authPasswordLabel,
                      ),
                      validator: (v) {
                        if ((v ?? '').isEmpty) return l10n.authPasswordRequired;
                        if (!_isLogin && v!.length < 8) {
                          return l10n.authPasswordTooShort;
                        }
                        return null;
                      },
                    ),
                    if (!_isLogin) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _displayNameController,
                        autofillHints: const [AutofillHints.name],
                        decoration: InputDecoration(
                          labelText: l10n.authDisplayNameLabel,
                        ),
                      ),
                    ],
                    if (auth.error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        auth.error!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (!_isLogin) ...[
                      LegalConsentCheckbox(
                        value: _agreedToTerms,
                        onChanged: (v) => setState(() => _agreedToTerms = v),
                      ),
                      const SizedBox(height: 8),
                    ],
                    FilledButton(
                      onPressed: auth.loading || (!_isLogin && !_agreedToTerms)
                          ? null
                          : _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: auth.loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _isLogin
                                  ? l10n.authSignIn
                                  : l10n.authCreateAccount,
                            ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: auth.loading ? null : _toggleMode,
                      child: Text(
                        _isLogin
                            ? l10n.authNoAccountPrompt
                            : l10n.authHaveAccountPrompt,
                      ),
                    ),
                    if (_isLogin)
                      TextButton(
                        onPressed: auth.loading ? null : _forgotPassword,
                        child: Text(l10n.authForgotPassword),
                      ),
                    const SsoButtons(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Step 1 of forgot-password: request the emailed reset code.
class _RequestResetDialog extends StatefulWidget {
  final String initialEmail;
  final Future<void> Function(String email) onRequest;
  const _RequestResetDialog({
    required this.initialEmail,
    required this.onRequest,
  });

  @override
  State<_RequestResetDialog> createState() => _RequestResetDialogState();
}

class _RequestResetDialogState extends State<_RequestResetDialog> {
  late final TextEditingController _email = TextEditingController(
    text: widget.initialEmail,
  );
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = context.l10n.authEmailInvalid);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onRequest(email);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.authResetDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.authResetDialogBody),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(
              labelText: l10n.authEmailLabel,
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: Text(_sending ? l10n.authSending : l10n.authSendCode),
        ),
      ],
    );
  }
}

/// Step 2 of forgot-password: enter the emailed code and a new password.
class _EnterResetCodeDialog extends StatefulWidget {
  final Future<void> Function(String code, String newPassword) onReset;
  const _EnterResetCodeDialog({required this.onReset});

  @override
  State<_EnterResetCodeDialog> createState() => _EnterResetCodeDialogState();
}

class _EnterResetCodeDialogState extends State<_EnterResetCodeDialog> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = context.l10n.authCodeRequired);
      return;
    }
    if (_password.text.length < 8) {
      setState(() => _error = context.l10n.authPasswordTooShort);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onReset(_code.text.trim(), _password.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.authEnterCodeTitle),
      content: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.authEnterCodeBody),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              autocorrect: false,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: InputDecoration(labelText: l10n.authResetCodeLabel),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: l10n.authNewPasswordLabel,
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? l10n.authSaving : l10n.authSetNewPassword),
        ),
      ],
    );
  }
}
