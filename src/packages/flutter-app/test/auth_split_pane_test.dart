import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/auth_screen.dart';
import 'package:travel_route_planner/services/auth_service.dart';
import 'package:travel_route_planner/services/auth_storage.dart';
import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/theme/app_theme.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';

import 'support/l10n_test_app.dart';

/// The split-pane photo layout (specs/auth-redesign): a full-height Santorini
/// pane beside the form on wide screens, a pinned band above it on tall
/// phones, and — the contract the older auth tests rely on — exactly the
/// pre-photo screen on short viewports. The form column itself is pinned by
/// auth_screen_sso_order_test.dart; this file pins what surrounds it.
class _FakeAuthService extends AuthService {
  _FakeAuthService() : super(baseUrl: 'http://unused');

  @override
  Future<bool> googleSignInAvailable() async => false;

  @override
  Future<bool> appleSignInAvailable() async => false;
}

class _FakeAuthStorage extends AuthStorage {
  @override
  Future<String?> loadToken() async => null;

  @override
  Future<void> saveToken(String value) async {}

  @override
  Future<void> clearToken() async {}
}

Future<void> _pumpAuth(
  WidgetTester tester,
  Size surface, {
  bool initialIsLogin = true,
  Locale? locale,
  ThemeData? theme,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(_FakeAuthService()),
      authStorageProvider.overrideWithValue(_FakeAuthStorage()),
    ],
    child: localizedTestApp(
      home: AuthScreen(initialIsLogin: initialIsLogin),
      locale: locale,
      theme: theme,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final panel = find.byKey(const Key('auth-photo-panel'));
  final tagline = find.text('Plan less. Travel more.');

  // The photo stack is layered DecoratedBoxes; both gradients have value
  // equality, so the layers can be asserted structurally. The gradient
  // sitting UNDER the image is also the no-photo fallback contract — the
  // image's errorBuilder collapses to nothing and leaves it showing.
  Finder gradientLayer(Gradient gradient) => find.descendant(
        of: panel,
        matching: find.byWidgetPredicate((w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient == gradient),
      );

  testWidgets('wide shows the full-height photo pane beside the form',
      (tester) async {
    await _pumpAuth(tester, const Size(1280, 800));

    expect(panel, findsOneWidget);
    // Full-height and starting at the top edge — the pane runs behind the
    // transparent app bar.
    expect(tester.getTopLeft(panel).dy, 0);
    expect(tester.getSize(panel).height, 800);

    // The scrim over the photo and the branded fallback under it.
    expect(gradientLayer(AppColors.heroScrim), findsOneWidget);
    expect(gradientLayer(AppColors.brandGradient), findsOneWidget);

    // The tagline lives on the photo side, left of the form.
    expect(tagline, findsOneWidget);
    expect(tester.getTopLeft(tagline).dx,
        lessThan(tester.getTopLeft(find.byType(TextFormField).first).dx));
  });

  testWidgets('wide keeps the 420px auth column', (tester) async {
    await _pumpAuth(tester, const Size(1280, 800));

    expect(tester.getSize(find.byType(TextFormField).first).width, 420);

    // The wordmark centers over the column like the mark above it — the
    // stretch column otherwise paints its text run from the left edge.
    expect(
        tester.getCenter(find.byType(BrandWordmark)).dx,
        closeTo(
            tester.getCenter(find.byType(TextFormField).first).dx, 0.01));
  });

  testWidgets('wide bar: white back slot, theme-colored globe',
      (tester) async {
    await _pumpAuth(tester, const Size(1280, 800));

    final bar = tester.widget<AppBar>(find.byType(AppBar));
    // The leading back arrow sits over the photo; the actions (the language
    // globe) sit over the form pane's own surface and must NOT be forced
    // white there. A null actionsIconTheme is NOT enough — it falls back to
    // the white iconTheme (the CDP run caught the invisible globe) — so the
    // M3 actions default has to be restated explicitly.
    expect(bar.iconTheme?.color, Colors.white);
    expect(
        bar.actionsIconTheme?.color,
        Theme.of(tester.element(find.byType(AppBar)))
            .colorScheme
            .onSurfaceVariant);
  });

  testWidgets('narrow tall shows the band pinned above the form',
      (tester) async {
    await _pumpAuth(tester, const Size(420, 1200));

    expect(panel, findsOneWidget);
    // Pinned at the very top (behind the bar), clamped to its max height.
    expect(tester.getTopLeft(panel).dy, 0);
    expect(tester.getSize(panel).height, 220);
    expect(tester.getSize(panel).width, 420);

    // Tagline on the band, above the form.
    expect(tester.getTopLeft(tagline).dy,
        lessThan(tester.getTopLeft(find.byType(TextFormField).first).dy));

    // Both bar slots float over the photo here.
    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.iconTheme?.color, Colors.white);
    expect(bar.actionsIconTheme?.color, Colors.white);
  });

  testWidgets('short viewports keep the pre-photo screen exactly',
      (tester) async {
    // The default test surface every older auth test pumps at — those tests
    // tap the submit button without ensureVisible, so this layout has to
    // stay byte-identical to the pre-photo screen.
    await _pumpAuth(tester, const Size(800, 600));

    expect(panel, findsNothing);
    expect(tagline, findsNothing);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.extendBodyBehindAppBar, isFalse);
    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.iconTheme, isNull);
    expect(bar.actionsIconTheme, isNull);
  });

  testWidgets('a keyboard-height viewport also skips the band',
      (tester) async {
    // 360x450 is auth_polish_test's keyboard-up floor.
    await _pumpAuth(tester, const Size(360, 450));

    expect(panel, findsNothing);
    expect(tagline, findsNothing);
  });

  testWidgets('Spanish sign-up on a phone renders the band without overflow',
      (tester) async {
    await _pumpAuth(tester, const Size(360, 690),
        initialIsLogin: false, locale: const Locale('es'));

    expect(panel, findsOneWidget);
    expect(find.text('Planea menos. Viaja más.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark theme: the photo stays committed-dark, the form follows',
      (tester) async {
    await _pumpAuth(tester, const Size(1280, 800), theme: AppTheme.dark);

    expect(panel, findsOneWidget);
    // The tagline is white by construction (it sits on the scrim, not on a
    // theme surface), in both themes.
    expect(tester.widget<Text>(tagline).style?.color, Colors.white);
    expect(tester.takeException(), isNull);
  });
}
