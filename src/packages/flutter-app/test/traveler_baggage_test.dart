import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/screens/onboarding_quiz_screen.dart';
import 'package:travel_route_planner/screens/preferences_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';

import 'support/l10n_test_app.dart';

/// specs/traveler-baggage — the profile row and quiz step behind bag-aware
/// flight pricing. The flight side (what the tier does to a search) lives in
/// flight_round_trip_test.dart; these pin that the answer round-trips as its
/// canonical API value on both surfaces that collect it.

class _FakePrefsApi implements PreferencesApiService {
  TravelerPreferences prefs;
  String? savedBaggage;
  int saveCalls = 0;

  _FakePrefsApi({this.prefs = const TravelerPreferences()});

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async => prefs;

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
    String? fitnessRoutine,
    String? outdoorIntensity,
    String? companions,
    String? baggage,
  }) async {
    saveCalls++;
    savedBaggage = baggage;
    prefs = TravelerPreferences(baggage: baggage);
    return prefs;
  }
}

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Test User',
      needsOnboarding: true,
      createdAt: DateTime(2026, 1, 1),
    );

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

Future<void> _pumpProfile(WidgetTester tester, _FakePrefsApi api) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [preferencesApiServiceProvider.overrideWithValue(api)],
    child: localizedTestApp(home: const PreferencesScreen()),
  ));
  await tester.pumpAndSettle();
}

bool _chipSelected(WidgetTester tester, String label) => tester
    .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
    .selected;

/// The profile is a long ListView, so this row sits below the test viewport;
/// scroll it in or the tap silently misses.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  group('travel profile: bags', () {
    testWidgets('renders the row with every tier', (tester) async {
      await _pumpProfile(tester, _FakePrefsApi());

      expect(find.text('What you fly with'), findsOneWidget);
      for (final label in ['Personal item', 'Carry-on', 'Checked bag']) {
        expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
      }
    });

    testWidgets('seeds the chip from the loaded profile', (tester) async {
      await _pumpProfile(
        tester,
        _FakePrefsApi(prefs: const TravelerPreferences(baggage: 'checked')),
      );

      expect(_chipSelected(tester, 'Checked bag'), isTrue);
      expect(_chipSelected(tester, 'Carry-on'), isFalse);
    });

    testWidgets('saves the canonical API value, not the label', (tester) async {
      final api = _FakePrefsApi();
      await _pumpProfile(tester, api);

      await _tapVisible(tester, find.widgetWithText(ChoiceChip, 'Carry-on'));
      await _tapVisible(tester, find.text('Save'));
      await tester.pumpAndSettle();

      expect(api.saveCalls, 1);
      expect(api.savedBaggage, 'carry_on');
    });

    // "I only bring a personal item" is an answer that turns bag pricing OFF,
    // not an absence — it has to reach the server as a value.
    testWidgets('personal item saves as a value', (tester) async {
      final api = _FakePrefsApi();
      await _pumpProfile(tester, api);

      await _tapVisible(
          tester, find.widgetWithText(ChoiceChip, 'Personal item'));
      await _tapVisible(tester, find.text('Save'));
      await tester.pumpAndSettle();

      expect(api.savedBaggage, 'personal_item');
    });
  });

  group('signup quiz: bags', () {
    testWidgets('the bag step saves the answer', (tester) async {
      final api = _FakePrefsApi();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          preferencesApiServiceProvider.overrideWithValue(api),
          authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        ],
        child: localizedTestApp(home: const OnboardingQuizScreen()),
      ));
      await tester.pump();

      // style -> work -> interests -> active -> companions -> home airport ->
      // bags (step 7 of 8).
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(find.text('What do you fly with?'), findsOneWidget);
      expect(find.text('Step 7 of 8'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Checked bag'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finish'));
      await tester.pump();

      expect(api.savedBaggage, 'checked');
    });

    // Every new preference field has to be seeded in _seedFrom, or an
    // untouched retake shows a blank row over a stored value and then saves
    // the blank.
    testWidgets('a retake seeds the saved answer', (tester) async {
      final api =
          _FakePrefsApi(prefs: const TravelerPreferences(baggage: 'carry_on'));
      await tester.pumpWidget(ProviderScope(
        overrides: [preferencesApiServiceProvider.overrideWithValue(api)],
        child:
            localizedTestApp(home: const OnboardingQuizScreen(retake: true)),
      ));
      await tester.pump();
      await tester.pump();

      for (var i = 0; i < 6; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(_chipSelected(tester, 'Carry-on'), isTrue);
    });
  });
}
