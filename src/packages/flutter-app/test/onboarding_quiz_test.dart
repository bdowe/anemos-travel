import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/screens/landing_screen.dart';
import 'package:travel_route_planner/screens/onboarding_quiz_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/widgets/empty_state.dart';

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

/// Controllable preferences backend: hang on a completer, fail, or answer
/// with a canned profile — so the retake seeding gate can be exercised.
class _FakePrefsService implements PreferencesApiService {
  Completer<TravelerPreferences>? pending;
  Object? failWith;
  TravelerPreferences result = const TravelerPreferences();
  int getCalls = 0;
  String? savedWorkStyle;

  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<TravelerPreferences> getPreferences() {
    getCalls++;
    if (pending != null) return pending!.future;
    final f = failWith;
    if (f != null) return Future.error(f);
    return Future.value(result);
  }

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
  }) async {
    savedWorkStyle = workStyle;
    return result;
  }
}

Future<void> _pumpRetake(WidgetTester tester, _FakePrefsService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [preferencesApiServiceProvider.overrideWithValue(service)],
      child: localizedTestApp(home: const OnboardingQuizScreen(retake: true)),
    ),
  );
  await tester.pump();
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
      expect(
          buildOnboardingProfileNotes(companions: null, tripsInMind: ''), '');
      expect(
          buildOnboardingProfileNotes(companions: null, tripsInMind: '  \n '),
          '');
    });

    test('companions only', () {
      expect(
        buildOnboardingProfileNotes(companions: 'partner', tripsInMind: ''),
        '- Travels with: partner',
      );
    });

    test('trips only, trimmed', () {
      expect(
        buildOnboardingProfileNotes(
            companions: null, tripsInMind: ' Japan in spring '),
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

  group('retake seeding gate', () {
    testWidgets(
        'slow preferences load shows a spinner and keeps Finish unreachable',
        (tester) async {
      final service = _FakePrefsService()..pending = Completer();
      await _pumpRetake(tester, service);

      // Gated: a deliberate loading state, no quiz form, no way to Finish
      // (which would save the empty answers over the stored profile).
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
      expect(find.text('Finish'), findsNothing);
      expect(find.text('Next'), findsNothing);

      // The saved profile lands -> the form appears, seeded.
      service.pending!.complete(const TravelerPreferences(
        budget: 'luxury',
        pace: 'packed',
        interests: ['food'],
      ));
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
      final luxury =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'luxury'));
      expect(luxury.selected, isTrue);
    });

    testWidgets('failing preferences load shows an error state with retry',
        (tester) async {
      final service = _FakePrefsService()..failWith = Exception('api down');
      await _pumpRetake(tester, service);
      await tester.pump();

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
      expect(find.text('Finish'), findsNothing);
      // Fixed copy, never the raw error string.
      expect(find.textContaining('api down'), findsNothing);

      // Backend recovers; retry releases the gate with the seeded profile.
      service
        ..failWith = null
        ..result = const TravelerPreferences(budget: 'mid');
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(EmptyState), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
      final mid =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'mid'));
      expect(mid.selected, isTrue);
      expect(service.getCalls, 2);
    });

    testWidgets('a legitimately-empty profile still releases the gate',
        (tester) async {
      final service = _FakePrefsService(); // empty TravelerPreferences
      await _pumpRetake(tester, service);
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
    });
  });

  group('work style step', () {
    testWidgets('selecting a chip and finishing saves work_style',
        (tester) async {
      final service = _FakePrefsService();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          preferencesApiServiceProvider.overrideWithValue(service),
          authProvider.overrideWith(
              (ref) => _FakeAuthNotifier(_user(needsOnboarding: true))),
        ],
        child: localizedTestApp(home: const OnboardingQuizScreen()),
      ));
      await tester.pump();

      // The work question is step 2 of 6.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Do you work while you travel?'), findsOneWidget);
      expect(find.text('Step 2 of 6'), findsOneWidget);

      await tester.tap(find.text('yes — I work as I travel'));
      await tester.pump();

      // Walk to the last step and finish.
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Finish'));
      await tester.pump();

      expect(service.savedWorkStyle, 'digital_nomad');
    });

    testWidgets('retake seeds the saved work style', (tester) async {
      final service = _FakePrefsService()
        ..result = const TravelerPreferences(workStyle: 'digital_nomad');
      await _pumpRetake(tester, service);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'yes — I work as I travel'));
      expect(chip.selected, isTrue);
    });
  });

  group('system back gesture', () {
    testWidgets('steps back to the previous question instead of leaving',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: localizedTestApp(home: const OnboardingQuizScreen()),
      ));
      await tester.pump();

      // Advance to step 2.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Do you work while you travel?'), findsOneWidget);
      expect(find.text('Step 2 of 6'), findsOneWidget);

      // System back: intercepted by PopScope -> back to step 1, quiz intact.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final handled = await navigator.maybePop();
      expect(handled, isTrue);
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingQuizScreen), findsOneWidget);
      expect(find.text("What's your travel style?"), findsOneWidget);
      expect(find.text('Step 1 of 6'), findsOneWidget);
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
