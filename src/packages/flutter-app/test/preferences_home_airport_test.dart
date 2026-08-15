import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/airport.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/screens/preferences_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/flights_api_service.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/widgets/airport_field.dart';

import 'support/l10n_test_app.dart';

/// Saving a home airport tells the truth about what was stored.
///
/// Two silent failures used to live here. Typing an airport without picking it
/// from the dropdown left the selection null, which went out as
/// `home_airport: null` — "omitted, keep existing" to the server — so the PUT
/// returned 200 with the OLD code and the screen said "Preferences saved".
/// And clearing the field was impossible for the same reason: nothing the
/// client could send meant "remove it".

class _FakePrefsApi implements PreferencesApiService {
  TravelerPreferences stored;
  int saveCalls = 0;
  final List<String?> homeAirportArgs = [];

  _FakePrefsApi({required this.stored});

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async => stored;

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
    homeAirportArgs.add(homeAirport);
    // Mirror the server: "" clears, a code replaces, null keeps.
    final next = homeAirport == null
        ? stored.homeAirport
        : (homeAirport.isEmpty ? null : homeAirport);
    stored = TravelerPreferences(
      budget: budget,
      pace: pace,
      interests: interests,
      homeAirport: next,
      profileNotes: profileNotes,
      workStyle: workStyle,
    );
    return stored;
  }
}

class _FakeFlightsApi extends FlightsApiService {
  _FakeFlightsApi() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Airport>> searchAirports(String query) async => const [
        Airport(
          iataCode: 'SEA',
          name: 'Seattle-Tacoma International Airport',
          city: 'Seattle',
          country: 'US',
          subType: 'airport',
        ),
      ];
}

Future<_FakePrefsApi> _pump(WidgetTester tester, {String? saved}) async {
  // The profile is ~2000px tall since the active-profile sections landed, so
  // the airport field and Save sit far below the default 800x600 surface and
  // taps miss the hit test. Give the test a surface tall enough to hold it all.
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final api = _FakePrefsApi(stored: TravelerPreferences(homeAirport: saved));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesApiServiceProvider.overrideWithValue(api),
        flightsApiServiceProvider.overrideWithValue(_FakeFlightsApi()),
      ],
      child: localizedTestApp(home: const PreferencesScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

/// The airport field specifically. `find.byType(TextField).first` would grab
/// the InterestPicker's "add an interest" box, which sits above this section.
Finder _airportFinder() => find.descendant(
      of: find.byType(AirportField),
      matching: find.byType(TextField),
    );

TextField _airportField(WidgetTester tester) =>
    tester.widget<TextField>(_airportFinder());

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('clearing the field sends an explicit clear, not a null',
      (t) async {
    final api = await _pump(t, saved: 'BOS');
    expect(_airportField(t).controller?.text, 'BOS');

    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    await _save(t);

    // "" is the clear signal; null would be COALESCEd back to BOS server-side.
    expect(api.homeAirportArgs, ['']);
    expect(api.stored.homeAirport, isNull);
    expect(_airportField(t).controller?.text, isEmpty);
  });

  testWidgets('typing without picking blocks the save and says why', (t) async {
    final api = await _pump(t, saved: 'BOS');

    await t.enterText(_airportFinder(), 'sea');
    await t.pumpAndSettle();
    await _save(t);

    expect(api.saveCalls, 0,
        reason: 'an unresolved edit must not reach the server as a no-op');
    expect(find.text('Pick an airport from the list, or clear the field.'),
        findsOneWidget);
    expect(find.text('Preferences saved'), findsNothing);
  });

  testWidgets('picking a suggestion clears the complaint and saves the code',
      (t) async {
    final api = await _pump(t, saved: 'BOS');

    await t.enterText(_airportFinder(), 'sea');
    await t.pumpAndSettle();
    await _save(t); // refused
    expect(api.saveCalls, 0);

    await t.tap(find.text('Seattle (SEA)'));
    await t.pumpAndSettle();
    expect(find.text('Pick an airport from the list, or clear the field.'),
        findsNothing);

    await _save(t);
    expect(api.homeAirportArgs, ['SEA']);
    expect(api.stored.homeAirport, 'SEA');
  });

  testWidgets('the form re-seeds from what the server stored', (t) async {
    final api = await _pump(t, saved: 'BOS');
    // Server normalizes to something other than what was sent.
    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    await _save(t);

    expect(api.stored.homeAirport, isNull);
    // The field shows the stored post-state, not a hopeful local one.
    expect(_airportField(t).controller?.text, isEmpty);
  });
}
