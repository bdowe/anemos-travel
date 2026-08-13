import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/theme_mode_provider.dart';
import 'package:travel_route_planner/screens/account_settings_screen.dart';
import 'package:travel_route_planner/services/account_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/theme/app_theme.dart';

import 'support/l10n_test_app.dart';

/// End-to-end of the user-visible half of specs/dark-mode: the Appearance
/// section in account settings restyles the whole app immediately, persists
/// the choice, and "Use device setting" follows the platform brightness live.
///
/// The MaterialApp here is wired exactly like main.dart (theme / darkTheme /
/// themeMode watched from the provider), so a tap on the real RadioListTile
/// proves the full loop, not just the provider. Fakes follow
/// settings_polish_test.dart.

class _FakeAccountApi implements AccountApiService {
  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  // The settings screen loads the Connected-apps section on build; serve
  // an empty list so pumping settles without network.
  @override
  Future<List<ConnectedApp>> listConnectedApps() async => const [];

  @override
  Future<void> revokeConnectedApp(String id) async {}

  @override
  Future<UserModel> updateDisplayName(String displayName) async => _user();

  @override
  Future<UserModel> updateLocale(String locale) async => _user();

  @override
  Future<({UserModel user, String token})> changePassword(
          String current, String newPassword) async =>
      (user: _user(), token: 'token');

  @override
  Future<UserModel> updateEmailPreferences({
    bool? remindersEnabled,
    bool? nudgesEnabled,
  }) async =>
      _user();

  @override
  Future<void> logoutAll() async {}

  @override
  Future<void> deleteAccount(String password) async {}
}

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
  void setUser(UserModel user) {
    state = state.copyWith(user: user);
  }

  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'user@example.com',
      displayName: 'Test User',
      isAdmin: false,
      createdAt: DateTime(2026, 1, 1),
    );

Future<void> _pumpSettings(WidgetTester tester) async {
  // Tall surface so the Appearance section is on-screen without scrolling
  // mechanics (same trick as settings_polish_test.dart).
  await tester.binding.setSurfaceSize(const Size(800, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(ProviderScope(
    overrides: [
      accountApiServiceProvider.overrideWithValue(_FakeAccountApi()),
      authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
    ],
    child: Consumer(builder: (context, ref, _) {
      final mode = ref.watch(themeModeProvider.select((s) => s.mode));
      return MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        supportedLocales: const [Locale('en'), Locale('es')],
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: const AccountSettingsScreen(),
      );
    }),
  ));
  await tester.pumpAndSettle();
}

Brightness _appBrightness(WidgetTester tester) =>
    Theme.of(tester.element(find.text('Appearance'))).brightness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping Dark restyles the app immediately and persists it',
      (tester) async {
    await _pumpSettings(tester);
    expect(_appBrightness(tester), Brightness.light);

    await tester.ensureVisible(find.text('Dark'));
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(_appBrightness(tester), Brightness.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
  });

  testWidgets('a stored Dark choice comes up dark on launch', (tester) async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    await _pumpSettings(tester);
    // The platform is light in tests — dark can only come from the store.
    expect(_appBrightness(tester), Brightness.dark);
  });

  testWidgets('"Use device setting" follows the platform brightness live',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    // Nothing stored: the default (system) mode tracks the OS.
    await _pumpSettings(tester);
    expect(_appBrightness(tester), Brightness.dark);

    // An OS appearance flip mid-session restyles without any tap.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(_appBrightness(tester), Brightness.light);
  });

  testWidgets('choosing Light pins the app against a dark platform',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await _pumpSettings(tester);
    expect(_appBrightness(tester), Brightness.dark);

    await tester.ensureVisible(find.text('Light'));
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(_appBrightness(tester), Brightness.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');
  });
}
