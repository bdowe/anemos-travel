import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';

import 'support/l10n_test_app.dart';

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

UserModel _user(String displayName) => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: displayName,
      createdAt: DateTime(2026, 1, 1),
    );

Future<void> _pumpHome(WidgetTester tester, UserModel? user) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(user)),
      ],
      child: localizedTestApp(home: const HomeScreen()),
    ),
  );
  await tester.pump();
}

/// The English copy for the current time of day, resolved through the same
/// AppLocalizations the widget under test used — so the assertion tracks the
/// ARB rather than duplicating the wording.
String _englishGreetingNow(WidgetTester tester) {
  final context = tester.element(find.byType(HomeScreen));
  return greetingText(context.l10n, greetingForHour(DateTime.now().hour));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('greetingForHour', () {
    test('morning until noon', () {
      expect(greetingForHour(0), Greeting.morning);
      expect(greetingForHour(11), Greeting.morning);
    });

    test('afternoon from noon until 5pm', () {
      expect(greetingForHour(12), Greeting.afternoon);
      expect(greetingForHour(16), Greeting.afternoon);
    });

    test('evening from 5pm', () {
      expect(greetingForHour(17), Greeting.evening);
      expect(greetingForHour(23), Greeting.evening);
    });
  });

  group('home greeting header', () {
    testWidgets('greets the user by first name only', (tester) async {
      await _pumpHome(tester, _user('Brian Dowe'));

      final greeting = _englishGreetingNow(tester);
      expect(find.text('$greeting, Brian'), findsOneWidget);
      expect(find.text('Where are we off to next?'), findsOneWidget);
    });

    testWidgets('falls back to a bare greeting when display name is empty',
        (tester) async {
      await _pumpHome(tester, _user(''));

      final greeting = _englishGreetingNow(tester);
      expect(find.text(greeting), findsOneWidget);
      expect(find.textContaining('$greeting,'), findsNothing);
    });
  });
}
