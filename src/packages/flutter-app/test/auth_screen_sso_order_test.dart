import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/auth_screen.dart';
import 'package:travel_route_planner/services/auth_service.dart';
import 'package:travel_route_planner/services/auth_storage.dart';

import 'support/l10n_test_app.dart';

/// One-tap sign-in is the default path: the SSO buttons sit ABOVE the email
/// form, separated from it by the "or" divider, and the legal small print
/// stays the page footer. Ordering is the entire point of that change, so it
/// gets asserted by geometry — presence-only checks (sso_buttons_test.dart)
/// pass just as happily with the block back at the bottom.
class _FakeAuthService extends AuthService {
  final bool google;
  final bool apple;
  _FakeAuthService({required this.google, required this.apple})
      : super(baseUrl: 'http://unused');

  @override
  Future<bool> googleSignInAvailable() async => google;

  @override
  Future<bool> appleSignInAvailable() async => apple;
}

class _FakeAuthStorage extends AuthStorage {
  @override
  Future<String?> loadToken() async => null;

  @override
  Future<void> saveToken(String value) async {}

  @override
  Future<void> clearToken() async {}
}

Widget _wrap({required bool google, required bool apple}) {
  return ProviderScope(
    overrides: [
      authServiceProvider
          .overrideWithValue(_FakeAuthService(google: google, apple: apple)),
      authStorageProvider.overrideWithValue(_FakeAuthStorage()),
    ],
    child: localizedTestApp(home: const AuthScreen()),
  );
}

/// Tall enough that the whole column stays on screen — the login form alone
/// nearly fills the default 800x600 surface, and `getTopLeft` on a widget
/// scrolled out of view is not what these assertions mean to compare.
Future<void> _pumpAuth(
  WidgetTester tester, {
  required bool google,
  required bool apple,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_wrap(google: google, apple: apple));
  // Drains the availability futures AND the 200ms AnimatedSize; measuring a
  // mid-animation frame would compare clipped positions.
  await tester.pumpAndSettle();
}

void main() {
  double y(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  // With Apple configured its black FilledButton precedes the submit button in
  // tree order, so `find.byType(FilledButton).first` is NOT "Sign in".
  final signInButton = find.ancestor(
    of: find.text('Sign in'),
    matching: find.byType(FilledButton),
  );
  final emailField = find.byType(TextFormField).first;

  testWidgets('Google sits above the "or" divider and the email form',
      (tester) async {
    await _pumpAuth(tester, google: true, apple: false);

    expect(y(tester, find.text('Continue with Google')),
        lessThan(y(tester, find.text('or'))));
    expect(y(tester, find.text('or')), lessThan(y(tester, emailField)));
    expect(y(tester, emailField), lessThan(y(tester, signInButton)));

    // The small print stays the footer rather than riding the buttons up.
    expect(y(tester, find.textContaining('Terms of Service')),
        greaterThan(y(tester, signInButton)));
  });

  testWidgets('Google above Apple, both above the form', (tester) async {
    await _pumpAuth(tester, google: true, apple: true);

    expect(y(tester, find.text('Continue with Google')),
        lessThan(y(tester, find.text('Continue with Apple'))));
    expect(y(tester, find.text('Continue with Apple')),
        lessThan(y(tester, find.text('or'))));
    expect(y(tester, find.text('or')), lessThan(y(tester, emailField)));
    expect(y(tester, emailField), lessThan(y(tester, signInButton)));
  });

  testWidgets('no provider configured leaves the form where it was',
      (tester) async {
    await _pumpAuth(tester, google: false, apple: false);

    expect(find.text('or'), findsNothing);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.textContaining('Terms of Service'), findsNothing);

    // The block collapses to nothing: the email field sits exactly one
    // AppSpacing.xl (24) under the title, as it did before SSO moved up.
    final title = find.text('Welcome back');
    expect(y(tester, emailField) - tester.getBottomLeft(title).dy,
        closeTo(24, 0.01));
  });
}
