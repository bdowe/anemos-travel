import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/reset_password_screen.dart';
import 'package:travel_route_planner/screens/sso_callback_screen.dart';
import 'package:travel_route_planner/screens/verify_email_screen.dart';
import 'package:travel_route_planner/services/auth_service.dart';
import 'package:travel_route_planner/widgets/auth_photo_panel.dart';
import 'package:travel_route_planner/widgets/empty_state.dart';
import 'package:travel_route_planner/widgets/gradient_app_bar.dart';

import 'support/l10n_test_app.dart';

/// The family pass (specs/auth-redesign): the deep-link siblings — reset
/// password, verify email, and the SSO callback — wear the same photo
/// composition as the sign-in screen, via the shared AuthPhotoBody. Unlike
/// the sign-in screen they keep their GradientAppBar (the landing page's
/// bar-over-photo precedent), so the photo starts below the bar and the
/// band threshold measures the body box.
///
/// SSO cases pump `code: 'error'` — the OAuth-declined path, which reaches
/// the failure state synchronously without touching the auth service.
class _FakeAuthService extends AuthService {
  final bool verifySucceeds;
  _FakeAuthService({this.verifySucceeds = true})
      : super(baseUrl: 'http://unused');

  @override
  Future<void> verifyEmail(String token) async {
    if (!verifySucceeds) throw Exception('expired');
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen,
  Size surface, {
  bool verifySucceeds = true,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authServiceProvider
          .overrideWithValue(_FakeAuthService(verifySucceeds: verifySucceeds)),
    ],
    child: localizedTestApp(home: screen),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final panel = find.byKey(const Key('auth-photo-panel'));
  final tagline = find.text('Plan less. Travel more.');

  testWidgets('reset: wide shows the pane beside the unchanged 420 column',
      (tester) async {
    await _pump(tester, const ResetPasswordScreen(token: 't'),
        const Size(1280, 800));

    expect(panel, findsOneWidget);
    expect(tagline, findsOneWidget);
    // The gradient bar survives the pass, and the photo starts below it.
    expect(find.byType(GradientAppBar), findsOneWidget);
    expect(tester.getTopLeft(panel).dy,
        tester.getBottomLeft(find.byType(AppBar)).dy);
    expect(tester.getSize(find.byType(TextFormField).first).width, 420);

    // WIDE-discriminating (the verify workflow's mutation run proved the
    // band branch satisfies everything above): the pane is exactly the
    // window minus the form pane, and the tagline sits LEFT of the form.
    expect(tester.getSize(panel).width, 1280 - authFormPaneWidth(1280));
    expect(tester.getTopLeft(tagline).dx,
        lessThan(tester.getTopLeft(find.byType(TextFormField).first).dx));
  });

  testWidgets('reset: tall phone gets the band above the form',
      (tester) async {
    await _pump(tester, const ResetPasswordScreen(token: 't'),
        const Size(420, 1200));

    expect(panel, findsOneWidget);
    expect(tester.getTopLeft(panel).dy,
        tester.getBottomLeft(find.byType(AppBar)).dy);
    expect(tester.getTopLeft(tagline).dy,
        lessThan(tester.getTopLeft(find.byType(TextFormField).first).dy));
    // BAND-discriminating: full-width, clamped to the band's max height.
    expect(tester.getSize(panel).width, 420);
    expect(tester.getSize(panel).height, 220);
  });

  testWidgets('reset: short viewports keep the pre-photo screen',
      (tester) async {
    await _pump(tester, const ResetPasswordScreen(token: 't'),
        const Size(800, 600));

    expect(panel, findsNothing);
    expect(tagline, findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(2));
  });

  testWidgets('verify: success outcome sits beside the pane on wide',
      (tester) async {
    await _pump(tester, const VerifyEmailScreen(token: 't'),
        const Size(1280, 800));

    expect(panel, findsOneWidget);
    // Outcome-specific, not just an EmptyState — the screen renders one for
    // BOTH outcomes, so the icon is what tells success from failure.
    expect(find.byIcon(Icons.mark_email_read_outlined), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(find.byType(GradientAppBar), findsOneWidget);
    // WIDE-discriminating, as on the reset test.
    expect(tester.getSize(panel).width, 1280 - authFormPaneWidth(1280));
  });

  testWidgets('verify: failure outcome gets the band on a tall phone',
      (tester) async {
    await _pump(tester, const VerifyEmailScreen(token: 't'),
        const Size(420, 1200),
        verifySucceeds: false);

    expect(panel, findsOneWidget);
    // The failure outcome specifically — an EmptyState alone can't tell it
    // from success, and takeException() is vacuous (the screen catches).
    expect(find.byIcon(Icons.link_off), findsOneWidget);
    expect(find.byIcon(Icons.mark_email_read_outlined), findsNothing);
    // BAND-discriminating: full-width at the clamped max height.
    expect(tester.getSize(panel).width, 420);
    expect(tester.getSize(panel).height, 220);
  });

  testWidgets('verify: short viewports keep the pre-photo screen',
      (tester) async {
    await _pump(tester, const VerifyEmailScreen(token: 't'),
        const Size(800, 600));

    expect(panel, findsNothing);
    expect(find.byType(EmptyState), findsOneWidget);
  });

  testWidgets('sso error: the failure sits beside the pane on wide',
      (tester) async {
    await _pump(tester, const SsoCallbackScreen(code: 'error'),
        const Size(1280, 800));

    expect(find.byIcon(Icons.link_off), findsOneWidget);
    expect(find.byType(GradientAppBar), findsOneWidget);
    // WIDE-discriminating, as on the reset/verify tests.
    expect(tester.getSize(panel).width, 1280 - authFormPaneWidth(1280));
  });

  testWidgets('sso error: tall phone gets the band', (tester) async {
    await _pump(tester, const SsoCallbackScreen(code: 'error'),
        const Size(420, 1200));

    expect(find.byIcon(Icons.link_off), findsOneWidget);
    // BAND-discriminating: full-width at the clamped max height.
    expect(tester.getSize(panel).width, 420);
    expect(tester.getSize(panel).height, 220);
  });

  testWidgets('sso error: short viewports keep the pre-photo screen',
      (tester) async {
    await _pump(tester, const SsoCallbackScreen(code: 'error'),
        const Size(800, 600));

    expect(panel, findsNothing);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });
}
