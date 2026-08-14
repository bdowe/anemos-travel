import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/auth_screen.dart';
import 'package:travel_route_planner/services/auth_service.dart';
import 'package:travel_route_planner/services/auth_storage.dart';
import 'package:travel_route_planner/widgets/legal_links.dart';

import 'support/l10n_test_app.dart';

/// Auth-entry polish (polish/auth-entry): friendly localized errors instead
/// of raw exception dumps, stale-error clearing on mode toggle, a tappable
/// consent row, and keyboard-safe (scrollable) forgot-password dialogs.
class _FakeAuthService extends AuthService {
  final Object? loginError;
  bool resetRequested = false;

  _FakeAuthService({this.loginError}) : super(baseUrl: 'http://unused');

  static final _user = UserModel(
    id: 'u1',
    email: 'traveler@example.com',
    displayName: 'Traveler',
    createdAt: DateTime.utc(2026, 1, 1),
  );

  @override
  Future<AuthResponse> login(String email, String password) async {
    if (loginError != null) throw loginError!;
    return AuthResponse(user: _user, token: 'tok');
  }

  @override
  Future<void> requestPasswordReset(String email) async {
    resetRequested = true;
  }

  @override
  Future<void> resetPassword(String code, String newPassword) async {}

  @override
  Future<bool> googleSignInAvailable() async => false;

  @override
  Future<bool> appleSignInAvailable() async => false;
}

class _FakeAuthStorage extends AuthStorage {
  String? token;

  @override
  Future<String?> loadToken() async => token;

  @override
  Future<void> saveToken(String value) async => token = value;

  @override
  Future<void> clearToken() async => token = null;
}

Widget _wrap(_FakeAuthService service,
    {Locale? locale, bool initialIsLogin = true}) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(service),
      authStorageProvider.overrideWithValue(_FakeAuthStorage()),
    ],
    child: localizedTestApp(
      locale: locale,
      home: AuthScreen(initialIsLogin: initialIsLogin),
    ),
  );
}

/// The Nth TextField INSIDE the open dialog — the auth form behind it also
/// contains TextFields (inside its TextFormFields), so bare byType finders
/// would match those first.
Finder _dialogField(int index) => find
    .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
    .at(index);

/// The email submit button, by its label. Deliberately NOT
/// `find.byType(FilledButton).first`: the SSO block now precedes the form and
/// Apple's button is a FilledButton too, so `.first` would silently become
/// "Continue with Apple" the moment a fake here reports Apple available.
Finder _submitButton(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(FilledButton));

Future<void> _signInAttempt(WidgetTester tester,
    {String label = 'Sign in'}) async {
  await tester.enterText(
      find.byType(TextFormField).at(0), 'traveler@example.com');
  await tester.enterText(find.byType(TextFormField).at(1), 'wrong-password');
  await tester.tap(_submitButton(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a 401 shows localized wrong-credentials copy, not raw prose',
      (tester) async {
    final service = _FakeAuthService(
        loginError: AuthException(
            statusCode: 401, message: 'invalid email or password'));
    await tester.pumpWidget(_wrap(service, locale: const Locale('es')));
    await tester.pump();

    await _signInAttempt(tester, label: 'Iniciar sesión');

    expect(find.text('Correo o contraseña incorrectos.'), findsOneWidget);
    expect(find.textContaining('invalid email'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
  });

  testWidgets('an unexpected error renders the generic localized message',
      (tester) async {
    final service = _FakeAuthService(loginError: StateError('socket exploded'));
    await tester.pumpWidget(_wrap(service));
    await tester.pump();

    await _signInAttempt(tester);

    expect(find.textContaining('socket exploded'), findsNothing);
    expect(
        find.text('Something went wrong. Please try again.'), findsOneWidget);
  });

  testWidgets('switching between sign-in and sign-up clears the stale error',
      (tester) async {
    final service = _FakeAuthService(
        loginError: AuthException(statusCode: 401, message: 'nope'));
    await tester.pumpWidget(_wrap(service));
    await tester.pump();

    await _signInAttempt(tester);
    expect(find.text('Wrong email or password.'), findsOneWidget);

    await tester.tap(find.textContaining("Don't have an account"));
    await tester.pumpAndSettle();
    expect(find.text('Wrong email or password.'), findsNothing);
  });

  testWidgets('tapping the consent label toggles the checkbox (whole row)',
      (tester) async {
    final service = _FakeAuthService();
    await tester.pumpWidget(_wrap(service, initialIsLogin: false));
    await tester.pumpAndSettle();

    Checkbox box() => tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box().value, isFalse);

    // Tap the row's label area (not the box itself): must toggle consent.
    await tester.tap(find.byType(LegalConsentCheckbox));
    await tester.pump();
    expect(box().value, isTrue);

    // Create-account button arms only once consent is given.
    final button =
        tester.widget<FilledButton>(_submitButton('Create account'));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('overflow floor: sign-up at 360x690 in es renders without errors',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 690));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _FakeAuthService(
        loginError: AuthException(statusCode: 409, message: 'dup'));
    await tester.pumpWidget(
        _wrap(service, locale: const Locale('es'), initialIsLogin: false));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'forgot-password dialogs survive a keyboard-sized viewport (scrollable)',
      (tester) async {
    // 360x450 approximates a phone with the software keyboard up.
    await tester.binding.setSurfaceSize(const Size(360, 450));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _FakeAuthService();
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    // The link can sit below the fold at this height — bring it on-screen.
    await tester.ensureVisible(find.text('Forgot password?'));
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect(find.text('Reset your password'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Step 1 -> step 2 (code + new password), the taller dialog.
    await tester.enterText(_dialogField(0), 'me@example.com');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    expect(service.resetRequested, isTrue);
    expect(find.text('Enter your reset code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected reset code errors under the code field',
      (tester) async {
    final service = _FakeAuthService();
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.enterText(_dialogField(0), 'me@example.com');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    // Submit with an empty code: the message must attach to the code field.
    await tester.tap(find.text('Set new password'));
    await tester.pump();
    final codeField = tester.widget<TextField>(_dialogField(0));
    expect(codeField.decoration?.errorText, 'Paste the code from the email');
    final passwordField = tester.widget<TextField>(_dialogField(1));
    expect(passwordField.decoration?.errorText, isNull);
  });
}
