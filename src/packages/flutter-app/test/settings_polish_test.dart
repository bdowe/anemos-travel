import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/notifications_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/screens/account_settings_screen.dart';
import 'package:travel_route_planner/screens/preferences_screen.dart';
import 'package:travel_route_planner/services/account_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/widgets/account_menu.dart';
import 'package:travel_route_planner/widgets/empty_state.dart';

import 'support/l10n_test_app.dart';

/// Settings/account polish wave (PR 3):
/// - preferences load-error gate (a failed GET must never reach the Save
///   button — Save is a full PUT that would wipe the server profile),
/// - confirm dialog before "Sign out everywhere",
/// - delete-account confirm disabled until a password is typed,
/// - account-menu overflow floor at phone width in Spanish.

class _FakePrefsApi implements PreferencesApiService {
  bool failGet;
  TravelerPreferences prefs;
  int getCalls = 0;

  _FakePrefsApi(
      {this.failGet = false, this.prefs = const TravelerPreferences()});

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async {
    getCalls++;
    if (failGet) {
      throw const ApiException(
          statusCode: 0, message: 'network down', endpoint: '/preferences');
    }
    return prefs;
  }

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
  }) async =>
      prefs;
}

class _FakeAccountApi implements AccountApiService {
  int logoutAllCalls = 0;
  final List<String> deletedWith = [];

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  /// The settings screen renders a Connected-apps section on load; these
  /// tests don't exercise it, so serve an empty list.
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
  Future<void> logoutAll() async {
    logoutAllCalls++;
  }

  @override
  Future<void> deleteAccount(String password) async {
    deletedWith.add(password);
  }
}

/// Auth notifier pinned to a fixed state, so screens can be pumped without
/// network or storage (same pattern as onboarding_quiz_test.dart).
class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

  int signOutLocallyCalls = 0;

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
  Future<void> signOutLocally() async {
    signOutLocallyCalls++;
  }

  @override
  void setUser(UserModel user) {
    state = state.copyWith(user: user);
  }

  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

UserModel _user({
  bool isAdmin = false,
  String displayName = 'Test User',
}) =>
    UserModel(
      id: 'user-1',
      email: 'una.direccion.de.correo.bastante.larga@example.com',
      displayName: displayName,
      isAdmin: isAdmin,
      createdAt: DateTime(2026, 1, 1),
    );

Future<_FakeAccountApi> _pumpAccountSettings(WidgetTester tester) async {
  // Tall surface: every section (sessions, danger zone) is on-screen, so the
  // tests exercise the dialogs rather than ListView scrolling mechanics.
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _FakeAccountApi();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      accountApiServiceProvider.overrideWithValue(api),
      authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
    ],
    child: localizedTestApp(home: const AccountSettingsScreen()),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The account settings language picker reads SharedPreferences on load.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('preferences load-error gate', () {
    testWidgets('failed GET shows EmptyState with Retry and no Save button',
        (tester) async {
      final api = _FakePrefsApi(failGet: true);
      await tester.pumpWidget(ProviderScope(
        overrides: [preferencesApiServiceProvider.overrideWithValue(api)],
        child: localizedTestApp(home: const PreferencesScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // The critical invariant: a blank-form Save is a full PUT that would
      // wipe the server profile, so Save must be unreachable.
      expect(find.text('Save'), findsNothing);
    });

    testWidgets('Retry after a failure loads and seeds the form',
        (tester) async {
      final api = _FakePrefsApi(
        failGet: true,
        prefs: const TravelerPreferences(
          budget: 'mid',
          pace: 'relaxed',
          interests: ['food'],
          profileNotes: 'Loves jazz clubs',
        ),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [preferencesApiServiceProvider.overrideWithValue(api)],
        child: localizedTestApp(home: const PreferencesScreen()),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(EmptyState), findsOneWidget);

      api.failGet = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(api.getCalls, 2);
      expect(find.byType(EmptyState), findsNothing);
      expect(find.text('Save'), findsOneWidget);
      // Seeded from the (retried) server profile, not blank.
      expect(find.text('Loves jazz clubs'), findsOneWidget);
    });
  });

  group('account settings', () {
    testWidgets('"Sign out everywhere" asks for confirmation first',
        (tester) async {
      final api = await _pumpAccountSettings(tester);

      await tester.ensureVisible(find.text('Sign out everywhere'));
      await tester.tap(find.text('Sign out everywhere'));
      await tester.pumpAndSettle();

      // Dialog is up; nothing has been called yet.
      expect(find.text('Sign out everywhere?'), findsOneWidget);
      expect(api.logoutAllCalls, 0);

      // Cancel leaves the sessions untouched.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.logoutAllCalls, 0);

      // Confirming actually signs out everywhere.
      await tester.tap(find.text('Sign out everywhere'));
      await tester.pumpAndSettle();
      await tester
          .tap(find.widgetWithText(FilledButton, 'Sign out everywhere'));
      await tester.pumpAndSettle();
      expect(api.logoutAllCalls, 1);
    });

    testWidgets(
        'delete-account confirm stays disabled until a password is typed',
        (tester) async {
      final api = await _pumpAccountSettings(tester);

      await tester.ensureVisible(find.text('Delete account'));
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();

      final confirm = find.widgetWithText(FilledButton, 'Delete forever');
      expect(confirm, findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'hunter22',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(api.deletedWith, ['hunter22']);
    });
  });

  group('account menu overflow floor', () {
    testWidgets('es menu at 360x690 renders every row without overflow',
        (tester) async {
      // AccountMenu's narrow/wide gate reads MediaQuery.sizeOf, which follows
      // the test view — setSurfaceSize alone would leave it at 800x600.
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(const Size(360, 690));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _FakeAuthNotifier(
              _user(isAdmin: true, displayName: 'María de los Ángeles'))),
          notificationsUnreadCountProvider.overrideWith((ref) => 3),
        ],
        child: localizedTestApp(
          locale: const Locale('es'),
          home: Scaffold(appBar: AppBar(actions: const [AccountMenu()])),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      // The two longest Spanish labels are present (admin rows included).
      expect(find.text('Repetir el cuestionario de viaje'), findsOneWidget);
      expect(find.text('Administración de info local'), findsOneWidget);
      // Widget tests rethrow RenderFlex overflows at test end automatically —
      // a clean settle with no exception IS the assertion.
      expect(tester.takeException(), isNull);
    });
  });
}
