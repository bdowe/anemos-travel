import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/locale_provider.dart';
import 'package:travel_route_planner/providers/theme_mode_provider.dart';
import 'package:travel_route_planner/screens/account_settings_screen.dart';
import 'package:travel_route_planner/services/account_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/theme/app_theme.dart';

import 'l10n_test_app.dart';

/// Shared harness for widget tests that drive the real [AccountSettingsScreen]
/// — the Appearance and Language dropdowns both live there, and both need the
/// same account fakes to pump without network. Fakes follow
/// settings_polish_test.dart.

class FakeAccountApi implements AccountApiService {
  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  // The settings screen loads the Connected-apps section on build; serve
  // an empty list so pumping settles without network.
  @override
  Future<List<ConnectedApp>> listConnectedApps() async => const [];

  @override
  Future<void> revokeConnectedApp(String id) async {}

  @override
  Future<UserModel> updateDisplayName(String displayName) async => testUser();

  @override
  Future<UserModel> updateLocale(String locale) async => testUser();

  @override
  Future<({UserModel user, String token})> changePassword(
          String current, String newPassword) async =>
      (user: testUser(), token: 'token');

  @override
  Future<UserModel> updateEmailPreferences({
    bool? remindersEnabled,
    bool? nudgesEnabled,
  }) async =>
      testUser();

  @override
  Future<void> logoutAll() async {}

  @override
  Future<void> deleteAccount(String password) async {}
}

class FakeAuthNotifier extends StateNotifier<AuthState> implements AuthNotifier {
  FakeAuthNotifier(UserModel? user)
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

UserModel testUser() => UserModel(
      id: 'user-1',
      email: 'user@example.com',
      displayName: 'Test User',
      isAdmin: false,
      createdAt: DateTime(2026, 1, 1),
    );

/// Pumps account settings inside a MaterialApp wired exactly like main.dart
/// (theme / darkTheme / themeMode / locale from the providers), so a pick from
/// a real dropdown proves the whole loop rather than just the provider.
///
/// [user] `null` signs the session out, which is what keeps
/// `LocaleNotifier.syncToAccount()` from reaching for the network; pass
/// [locale] to force a language instead of following `localeProvider`.
Future<void> pumpAccountSettings(
  WidgetTester tester, {
  // Tall surface so the section under test is on-screen without scrolling
  // mechanics (same trick as settings_polish_test.dart).
  Size size = const Size(800, 2000),
  Locale? locale,
  UserModel? user,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(ProviderScope(
    overrides: [
      accountApiServiceProvider.overrideWithValue(FakeAccountApi()),
      authProvider.overrideWith((ref) => FakeAuthNotifier(user)),
    ],
    child: Consumer(builder: (context, ref, _) {
      final mode = ref.watch(themeModeProvider.select((s) => s.mode));
      final appLocale =
          locale ?? ref.watch(localeProvider.select((s) => s.materialLocale));
      return MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        supportedLocales: kSupportedLocales,
        locale: appLocale,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: const AccountSettingsScreen(),
      );
    }),
  ));
  await tester.pumpAndSettle();
}
