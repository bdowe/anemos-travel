import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../theme/spacing.dart';
import '../widgets/brand_logo.dart';
import '../widgets/language_menu_button.dart';
import '../widgets/page_container.dart';
import '../widgets/sso_buttons.dart';
import '../widgets/legal_links.dart';
import '../utils/errors.dart';
import '../utils/snack.dart';

/// The landing family's established wide switch: at 900px and up the photo
/// becomes a full-height pane beside the form.
const double _kWideBreakpoint = 900;

/// The form pane's clamp on wide layouts. The floor is the 420px auth column
/// plus its two xl gutters, so the column never compresses; the cap keeps the
/// photograph dominant on ultrawide windows.
const double _kFormPaneMinWidth = 468;
const double _kFormPaneMaxWidth = 560;

/// Below the wide switch, the photo band appears only when the viewport is at
/// least this tall, so small phones and keyboard-up viewports keep the
/// pre-photo layout with the form fully in reach.
const double _kBandMinViewportHeight = 620;

/// The band takes 22% of the viewport within these bounds: enough photo to
/// set the scene, never enough to bury the fields.
const double _kBandMinHeight = 140;
const double _kBandMaxHeight = 220;

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
    final filled = value.isNotEmpty &&
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
    // The previous attempt's failure belongs to the other mode — showing
    // "wrong password" above a fresh create-account form is just confusing.
    ref.read(authProvider.notifier).clearError();
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
    // One LayoutBuilder decides the whole composition: the AppBar's icon
    // colors and the body have to agree on where the photo is, and layout
    // must follow the box this route was given — constraints, never
    // MediaQuery.sizeOf.
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= _kWideBreakpoint;
      // The pinned band earns its place only when the viewport is tall
      // enough to keep the form comfortably reachable below it. Deliberate
      // side effect: opening the keyboard shrinks maxHeight below the
      // threshold and the band yields its space to the form — form first
      // when typing. Not a bug to "fix" with MediaQuery.sizeOf.
      final showBand =
          !wide && constraints.maxHeight >= _kBandMinViewportHeight;
      final hasPhoto = wide || showBand;

      return Scaffold(
        // The photo reaches the top edge whenever it exists; without it,
        // this is exactly the pre-photo chrome.
        extendBodyBehindAppBar: hasPhoto,
        // Transparent AppBar so the implied back arrow gives a way back to
        // the landing page underneath (this screen is always pushed on top
        // of it).
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          // The back arrow sits over the photo in both photo layouts (left
          // pane on wide, top band on narrow); the globe is over the photo
          // only in the band layout — on wide it sits over the form pane's
          // own surface and keeps the theme color.
          iconTheme:
              hasPhoto ? const IconThemeData(color: Colors.white) : null,
          // A null actionsIconTheme FALLS BACK to iconTheme, so on wide the
          // white leading slot would leak onto the globe over the light form
          // pane — restate M3's own actions default (onSurfaceVariant) there.
          actionsIconTheme: showBand
              ? const IconThemeData(color: Colors.white)
              : wide
                  ? IconThemeData(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)
                  : null,
          actions: const [LanguageMenuButton()],
        ),
        body: wide
            ? Row(
                children: [
                  const Expanded(
                    child: _AuthPhotoPanel(
                      key: Key('auth-photo-panel'),
                      wide: true,
                    ),
                  ),
                  SizedBox(
                    // 45% of the window (the split-pane proportion of the
                    // field), floored so the 420px column and its gutters
                    // never compress, capped so the photo stays dominant
                    // on ultrawide screens.
                    width: (constraints.maxWidth * 0.45)
                        .clamp(_kFormPaneMinWidth, _kFormPaneMaxWidth),
                    // The transparent bar floats over this pane; give
                    // scroll-to-top room to clear it.
                    child: _formScroller(topInset: kToolbarHeight),
                  ),
                ],
              )
            : showBand
                ? Column(
                    children: [
                      SizedBox(
                        height: (constraints.maxHeight * 0.22)
                            .clamp(_kBandMinHeight, _kBandMaxHeight),
                        child: const _AuthPhotoPanel(
                          key: Key('auth-photo-panel'),
                          wide: false,
                        ),
                      ),
                      Expanded(child: _formScroller()),
                    ],
                  )
                : _formScroller(),
      );
    });
  }

  /// Today's auth body, verbatim — every layout shares it, so the form
  /// column (and the tests pinning its geometry) never changes shape.
  Widget _formScroller({double topInset = 0}) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final auth = ref.watch(authProvider);

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl + topInset,
            AppSpacing.xl, AppSpacing.xl),
        // The auth family's shared 420px column (see also reset/verify/SSO
        // screens) — PageContainer inside the scroll view, house pattern.
        child: PageContainer(
          maxWidth: 420,
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
                  const SizedBox(height: AppSpacing.sm),
                  // Neutral surface, so the wordmark takes the theme's own
                  // text color rather than the app bars' white — the plate
                  // policy in brand_logo.dart, applied to type.
                  const ExcludeSemantics(
                    // The mark's Image already carries the "Anemos" label.
                    // Centered explicitly: the stretch column otherwise
                    // paints the text run from the left edge, splitting it
                    // from the centered mark above (latent on the old flat
                    // screen; the pane composition exposed it).
                    child: Center(
                      child: BrandWordmark(fontSize: 26, letterSpacing: 1.5),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    _isLogin
                        ? l10n.authWelcomeBack
                        : l10n.authCreateAccountTitle,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  // One-tap sign-in first: position alone marks it the
                  // default path. The block owns the "or" divider that
                  // separates it from the email form below.
                  const SsoButtons(),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    // Mobile keyboards advance to the password field
                    // instead of dismissing.
                    textInputAction: TextInputAction.next,
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
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    autofillHints: [
                      _isLogin
                          ? AutofillHints.password
                          : AutofillHints.newPassword,
                    ],
                    // Last field when signing in; sign-up still has the
                    // display name below.
                    textInputAction: _isLogin
                        ? TextInputAction.done
                        : TextInputAction.next,
                    onFieldSubmitted: (_) {
                      if (_isLogin) _submit();
                    },
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
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _displayNameController,
                      autofillHints: const [AutofillHints.name],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.authDisplayNameLabel,
                      ),
                    ),
                  ],
                  if (auth.error != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      friendlyError(l10n, auth.error),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  if (!_isLogin) ...[
                    LegalConsentCheckbox(
                      value: _agreedToTerms,
                      onChanged: (v) => setState(() => _agreedToTerms = v),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  FilledButton(
                    onPressed: auth.loading || (!_isLogin && !_agreedToTerms)
                        ? null
                        : _submit,
                    style: FilledButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.lg),
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
                  const SizedBox(height: AppSpacing.md),
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
                  // Sign-in only: sign-up already states the terms in the
                  // blocking LegalConsentCheckbox above the button, and two
                  // copies on one screen read as boilerplate.
                  if (_isLogin) const SsoLegalAgreement(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The destination photograph that gives sign-in its atmosphere: a
/// full-height pane on wide layouts, a pinned top band on narrow ones.
/// The landing hero's photo stack — gradient fallback, cover photo,
/// heroScrim — without a logo: the form column already carries the brand,
/// and the landing hero records why a surface brands only once.
class _AuthPhotoPanel extends StatelessWidget {
  /// Pane vs band — decides the tagline's scale and padding.
  final bool wide;

  const _AuthPhotoPanel({super.key, required this.wide});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // Branded gradient behind the photo: visible until the image
          // decodes and whenever it fails to load, so the scrim and the
          // tagline always sit on a dark branded surface.
          DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.brandGradient),
          ),
          Image.asset(
            'assets/images/hero_santorini.jpg',
            fit: BoxFit.cover,
            // Decorative — the form column carries the screen's meaning.
            excludeFromSemantics: true,
            // Bound the decode to the panel, not the window: on wide
            // layouts this pane is roughly half the window. Quantized to
            // 320px buckets so a continuous resize reuses the cached
            // decode instead of minting one per pixel of width.
            cacheWidth: math.min(
              1600,
              ((constraints.maxWidth *
                          MediaQuery.devicePixelRatioOf(context)) /
                      320)
                  .ceil() *
                  320,
            ),
            // Hold the previous frame while a new bucket decodes
            // mid-resize.
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                child: child,
              );
            },
            // The gradient underneath is the fallback.
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.heroScrim),
          ),
          // The scrim is bottomLeft-darkest — the tagline sits exactly
          // there.
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.all(wide ? AppSpacing.xl : AppSpacing.lg),
              child: Text(
                context.l10n.authTagline,
                style: TextStyle(
                  // Marcellus ships only w400 — always stated, or web
                  // synthesizes faux-bold. Display sizes stated locally,
                  // the landing-hero precedent: 38 suits the half-window
                  // pane, 24 the band.
                  fontFamily: AppFonts.display,
                  fontWeight: FontWeight.w400,
                  fontSize: wide ? 38 : 24,
                  height: 1.15,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      );
    });
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
    // Captured before the await — the dialog can be dismissed mid-flight and
    // an inherited-widget lookup would then throw.
    final l10n = context.l10n;
    try {
      await widget.onRequest(email);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = friendlyError(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.authResetDialogTitle),
      // Content scrolls under a raised software keyboard instead of
      // overflowing (360×640-class phones lose ~40% of the viewport).
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.authResetDialogBody),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            onSubmitted: (_) => _send(),
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

  /// Two error slots so each message renders under the field it refers to:
  /// a missing/rejected code must not show up beneath the password box.
  String? _codeError;
  String? _passwordError;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    setState(() {
      _codeError = null;
      _passwordError = null;
    });
    if (_code.text.trim().isEmpty) {
      setState(() => _codeError = l10n.authCodeRequired);
      return;
    }
    if (_password.text.length < 8) {
      setState(() => _passwordError = l10n.authPasswordTooShort);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onReset(_code.text.trim(), _password.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          // The API 404s a wrong/expired code — that's the code field's
          // problem, not the password's.
          if (e is AuthException && e.statusCode == 404) {
            _codeError = l10n.authErrorBadResetCode;
          } else {
            _passwordError = friendlyError(l10n, e);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.authEnterCodeTitle),
      // Scrolls under the software keyboard instead of overflowing — this
      // dialog is exactly what raises it.
      scrollable: true,
      content: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.authEnterCodeBody),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _code,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: InputDecoration(
                labelText: l10n.authResetCodeLabel,
                errorText: _codeError,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: l10n.authNewPasswordLabel,
                errorText: _passwordError,
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
