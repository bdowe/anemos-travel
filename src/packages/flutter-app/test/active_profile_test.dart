import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/constants/interest_bank.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/screens/preferences_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';

import 'support/l10n_test_app.dart';

/// specs/active-profile — the three chip rows the Travel profile screen gained:
/// fitness routine, outdoor intensity and companions.
///
/// The load/save invariants themselves (error gate, full-PUT wipe guard) are
/// covered by settings_polish_test.dart; these pin that the new rows round-trip
/// their canonical API values rather than their localized labels.
class _FakePrefsApi implements PreferencesApiService {
  TravelerPreferences prefs;
  String? savedFitnessRoutine;
  String? savedOutdoorIntensity;
  String? savedCompanions;
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
  }) async {
    saveCalls++;
    savedFitnessRoutine = fitnessRoutine;
    savedOutdoorIntensity = outdoorIntensity;
    savedCompanions = companions;
    return prefs;
  }
}

Future<void> _pump(WidgetTester tester, _FakePrefsApi api) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [preferencesApiServiceProvider.overrideWithValue(api)],
    child: localizedTestApp(home: const PreferencesScreen()),
  ));
  await tester.pumpAndSettle();
}

bool _chipSelected(WidgetTester tester, String label) => tester
    .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
    .selected;

/// The profile is a long ListView, so the new rows sit below the 800x600 test
/// viewport — scroll them in before tapping or the tap silently misses.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  group('travel profile: active rows', () {
    testWidgets('renders all three new rows', (tester) async {
      await _pump(tester, _FakePrefsApi());

      expect(find.text('Working out'), findsOneWidget);
      expect(find.text('Outdoor days'), findsOneWidget);
      expect(find.text('Who you travel with'), findsOneWidget);

      // Every option is offered, including the explicit opt-out.
      for (final label in [
        'gym access',
        'running routes',
        'both',
        'not a factor',
      ]) {
        expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
      }
    });

    testWidgets('seeds the chips from the loaded profile', (tester) async {
      await _pump(
        tester,
        _FakePrefsApi(
          prefs: const TravelerPreferences(
            fitnessRoutine: 'both',
            outdoorIntensity: 'easy',
            companions: 'solo',
          ),
        ),
      );

      expect(_chipSelected(tester, 'both'), isTrue);
      expect(_chipSelected(tester, 'easy — walks and viewpoints'), isTrue);
      expect(_chipSelected(tester, 'solo'), isTrue);
      // Neighbours in the same row stay off.
      expect(_chipSelected(tester, 'gym access'), isFalse);
      expect(_chipSelected(tester, 'moderate — half-day hikes'), isFalse);
    });

    testWidgets('saves canonical API values, not the labels', (tester) async {
      final api = _FakePrefsApi();
      await _pump(tester, api);

      await _tapVisible(
          tester, find.widgetWithText(ChoiceChip, 'running routes'));
      await _tapVisible(tester,
          find.widgetWithText(ChoiceChip, 'challenging — long and steep'));
      await _tapVisible(
          tester, find.widgetWithText(ChoiceChip, 'family with kids'));
      await _tapVisible(tester, find.text('Save'));
      await tester.pumpAndSettle();

      expect(api.saveCalls, 1);
      expect(api.savedFitnessRoutine, 'running');
      expect(api.savedOutdoorIntensity, 'challenging');
      // Snake_case, matching the column — the pre-00063 quiz spelled this
      // "family with kids" and the server now rejects that.
      expect(api.savedCompanions, 'family_with_kids');
    });

    testWidgets('"not a factor" saves as a value, not as an absence',
        (tester) async {
      final api = _FakePrefsApi();
      await _pump(tester, api);

      await _tapVisible(
          tester, find.widgetWithText(ChoiceChip, 'not a factor'));
      await _tapVisible(tester, find.text('Save'));
      await tester.pumpAndSettle();

      expect(api.savedFitnessRoutine, 'none');
    });
  });

  group('interest bank', () {
    // The structured fitness field owns these, so having them here too would
    // give one fact two homes (docs/zen.md).
    test('does not duplicate the fitness routine values', () {
      expect(suggestedInterests, isNot(contains('gym')));
      expect(suggestedInterests, isNot(contains('running')));
    });

    test('carries the added outdoor tastes', () {
      for (final v in ['cycling', 'climbing', 'national parks']) {
        expect(suggestedInterests, contains(v));
      }
    });
  });
}
