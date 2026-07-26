import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/locale_provider.dart';
import 'package:travel_route_planner/screens/auth_screen.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/auth_service.dart';
import 'package:travel_route_planner/services/auth_storage.dart';
import 'package:travel_route_planner/widgets/gradient_app_bar.dart';
import 'package:travel_route_planner/widgets/language_menu_button.dart';

import 'support/l10n_test_app.dart';

/// The app-bar globe menu (specs/i18n-spanish, visible language switcher):
/// same three choices as the settings picker, checked on the override, and
/// present on the surfaces a signed-out visitor actually sees — including at
/// rail width, where AccountMenu hides itself and the globe must not.
///
/// The locale provider reads authProvider to decide whether to sync the
/// choice to the account; constructing the real AuthStorage hits
/// flutter_secure_storage, which has no implementation under `flutter test`.
class _FakeAuthStorage extends AuthStorage {
  String? token;

  @override
  Future<String?> loadToken() async => token;

  @override
  Future<void> saveToken(String value) async => token = value;

  @override
  Future<void> clearToken() async => token = null;
}

/// Records nothing; Google SSO reports unavailable so the button stays hidden.
class _FakeAuthService extends AuthService {
  _FakeAuthService() : super(baseUrl: 'http://unused');

  @override
  Future<bool> googleSignInAvailable() async => false;
}

class _NoopAnalytics implements AnalyticsApiService {
  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<void> recordLandingViewed() => Future.value();

  @override
  Future<void> recordBookingLinkClicked({
    String? tripId,
    String? todoKey,
    String? provider,
    String? surface,
    String? kind,
  }) =>
      Future.value();

  @override
  Future<void> recordItineraryItemAdded({
    required String tripId,
    required String source,
  }) =>
      Future.value();
}

/// Auth notifier pinned to a fixed signed-in state, so the home screen can be
/// pumped without network or storage.
class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

  @override
  void clearError() => state = state.copyWith(clearError: true);

  @override
  Future<bool> login(String email, String password) async => false;

  @override
  Future<bool> register(String email, String password,
          {String? displayName}) async =>
      false;

  @override
  Future<void> completeOnboarding() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<void> signOutLocally() async {}

  @override
  void setUser(UserModel user) {}

  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

bool _checkedOf(WidgetTester tester, String label) => tester
    .widget<CheckedPopupMenuItem<String>>(
        find.widgetWithText(CheckedPopupMenuItem<String>, label))
    .checked;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('menu lists System default, English and Español with the '
      'override checked', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [authStorageProvider.overrideWithValue(_FakeAuthStorage())],
      child: localizedTestApp(
        home: Scaffold(
          appBar: GradientAppBar(
            title: const Text('t'),
            actions: const [LanguageMenuButton()],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();

    expect(find.text('System default'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Español'), findsOneWidget);
    expect(_checkedOf(tester, 'System default'), isTrue);
    expect(_checkedOf(tester, 'English'), isFalse);
    expect(_checkedOf(tester, 'Español'), isFalse);
  });

  testWidgets('selecting Español switches the app and checks it in the menu',
      (tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [authStorageProvider.overrideWithValue(_FakeAuthStorage())],
      child: Consumer(builder: (context, r, _) {
        ref = r;
        final locale = r.watch(localeProvider.select((s) => s.materialLocale));
        return MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          supportedLocales: kSupportedLocales,
          locale: locale,
          home: Scaffold(
            appBar: AppBar(actions: const [LanguageMenuButton()]),
            body: Builder(
              builder: (context) => Text(context.l10n.languageSectionTitle),
            ),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'Español'));
    await tester.pumpAndSettle();

    expect(ref.read(localeProvider).override, 'es');
    expect(find.text('Idioma'), findsOneWidget);
    expect(find.text('Language'), findsNothing);

    // Reopened, the menu itself is now in Spanish, with Español checked.
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    expect(_checkedOf(tester, 'Español'), isTrue);
    expect(_checkedOf(tester, 'Predeterminado del sistema'), isFalse);
  });

  testWidgets('landing screen shows the globe signed out, even at rail width',
      (tester) async {
    LandingScreen.resetViewRecordedForTest();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    expect(1200, greaterThanOrEqualTo(kRailBreakpoint));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStorageProvider.overrideWithValue(_FakeAuthStorage()),
        analyticsApiServiceProvider.overrideWithValue(_NoopAnalytics()),
      ],
      child: localizedTestApp(home: const LandingScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(LanguageMenuButton), findsOneWidget);
    expect(find.byIcon(Icons.language), findsOneWidget);
  });

  testWidgets('home app bar shows the globe', (tester) async {
    // The default 800x600 surface sits exactly at kRailBreakpoint, where
    // AccountMenu renders nothing — the globe must still be there.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStorageProvider.overrideWithValue(_FakeAuthStorage()),
        authProvider.overrideWith((ref) => _FakeAuthNotifier(UserModel(
              id: 'user-1',
              email: 'test@example.com',
              displayName: 'Test',
              createdAt: DateTime(2026, 1, 1),
            ))),
      ],
      child: localizedTestApp(home: const HomeScreen()),
    ));
    await tester.pump();

    expect(find.byType(LanguageMenuButton), findsOneWidget);
  });

  testWidgets('sign-in screen shows the globe', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(_FakeAuthService()),
        authStorageProvider.overrideWithValue(_FakeAuthStorage()),
      ],
      child: localizedTestApp(home: const AuthScreen()),
    ));
    await tester.pump();

    expect(find.byType(LanguageMenuButton), findsOneWidget);
  });
}
