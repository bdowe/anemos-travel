import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/local_guide.dart';
import 'package:travel_route_planner/models/local_recommendation.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/providers/local_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/screens/flight_search_screen.dart';
import 'package:travel_route_planner/screens/local_guide_detail_screen.dart';
import 'package:travel_route_planner/screens/preferences_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/widgets/airport_field.dart';
import 'package:travel_route_planner/widgets/choice_chip_row.dart';
import 'package:travel_route_planner/widgets/local_rec_card.dart';

import 'support/l10n_test_app.dart';

/// Preferences now gates its form behind a successful GET (a failed load
/// shows an error state with no Save button), so the width sweep must feed
/// it a load that succeeds.
class _OkPrefsApi implements PreferencesApiService {
  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async =>
      const TravelerPreferences();

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
  }) async =>
      const TravelerPreferences();
}

/// Declutter sweep: preferences, flight search, and the guide reader cap
/// their content at PageContainer's 700px on wide layouts.
const _wide = Size(1200, 900);

Future<void> _setSurface(WidgetTester tester, Size s) async {
  await tester.binding.setSurfaceSize(s);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void _expectCapped(WidgetTester tester, Finder f) {
  expect(tester.getSize(f).width, lessThanOrEqualTo(700));
  final left = tester.getTopLeft(f).dx;
  final right = _wide.width - tester.getTopRight(f).dx;
  expect((left - right).abs(), lessThan(2));
}

const _guide = LocalGuide(
  id: 'g1',
  title: 'Alfama on foot',
  city: 'Lisboa',
  body: 'A slow morning through the oldest streets in the city…',
  sourceName: 'Rui',
);

void main() {
  testWidgets('preferences content caps at 700 on wide layouts',
      (tester) async {
    await _setSurface(tester, _wide);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesApiServiceProvider.overrideWithValue(_OkPrefsApi()),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: const PreferencesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    _expectCapped(tester, find.byType(ChoiceChipRow).first);
  });

  testWidgets('flight search form caps at 700 on wide layouts', (tester) async {
    await _setSurface(tester, _wide);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: const FlightSearchScreen()),
      ),
    );
    await tester.pump();
    _expectCapped(tester, find.byType(AirportField).first);
  });

  testWidgets('guide reader caps at 700 on wide, fills phones', (tester) async {
    await _setSurface(tester, _wide);
    Widget app() => ProviderScope(
          overrides: [
            localGuideDetailProvider('g1').overrideWith((ref) async =>
                (guide: _guide, recommendations: <LocalRecommendation>[])),
          ],
          child: MaterialApp(
              localizationsDelegates: testLocalizationsDelegates,
              home: const LocalGuideDetailScreen(guide: _guide)),
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    _expectCapped(tester, find.text('Alfama on foot'));
    expect(find.byType(LocalRecCard), findsNothing);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('Alfama on foot')).width, greaterThan(340));
  });
}
