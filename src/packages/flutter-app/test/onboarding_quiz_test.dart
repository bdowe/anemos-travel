import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/screens/onboarding_quiz_screen.dart';

import 'support/l10n_test_app.dart';

/// Auth notifier pinned to a fixed state, so AuthGate can be pumped without
/// network or storage.
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

UserModel _user({required bool needsOnboarding}) => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Test User',
      needsOnboarding: needsOnboarding,
      createdAt: DateTime(2026, 1, 1),
    );

Future<void> _pumpGate(WidgetTester tester, UserModel? user) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(user)),
      ],
      child: localizedTestApp(home: const AuthGate()),
    ),
  );
  await tester.pump();
}

void main() {
  group('buildOnboardingProfileNotes', () {
    test('empty answers produce no notes', () {
      expect(buildOnboardingProfileNotes(companions: null, tripsInMind: ''), '');
      expect(buildOnboardingProfileNotes(companions: null, tripsInMind: '  \n '), '');
    });

    test('companions only', () {
      expect(
        buildOnboardingProfileNotes(companions: 'partner', tripsInMind: ''),
        '- Travels with: partner',
      );
    });

    test('trips only, trimmed', () {
      expect(
        buildOnboardingProfileNotes(companions: null, tripsInMind: ' Japan in spring '),
        '- Trips in mind: Japan in spring',
      );
    });

    test('both answers become separate bullet lines', () {
      expect(
        buildOnboardingProfileNotes(
            companions: 'family with kids', tripsInMind: 'Greek islands'),
        '- Travels with: family with kids\n- Trips in mind: Greek islands',
      );
    });

    test('newlines in the trips text collapse to semicolons', () {
      expect(
        buildOnboardingProfileNotes(
            companions: null, tripsInMind: 'Japan in spring\nPatagonia trek'),
        '- Trips in mind: Japan in spring; Patagonia trek',
      );
    });
  });

  group('AuthGate onboarding routing', () {
    testWidgets('shows the quiz for a signed-in user who needs onboarding',
        (tester) async {
      await _pumpGate(tester, _user(needsOnboarding: true));

      expect(find.byType(OnboardingQuizScreen), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
    });

    testWidgets('shows the landing page when signed out', (tester) async {
      await _pumpGate(tester, null);

      expect(find.byType(LandingScreen), findsOneWidget);
      expect(find.byType(OnboardingQuizScreen), findsNothing);
    });
  });
}
