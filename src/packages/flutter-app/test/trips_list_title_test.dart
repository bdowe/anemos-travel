import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/live_trip_card.dart';

import 'support/l10n_test_app.dart';

/// Trip cards headline the trip's own title — the same name the detail header
/// shows — with the cities summary demoted to a subtitle line. The cities
/// label is only promoted to headline for legacy trips whose stored "title"
/// is really the AI summary (tripTitleIsLong in utils/trip_format.dart).
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;
  _FixedTripsApiService(this.trips)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() => Future.value(trips);
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Trip _trip(String id, String title, {List<String>? cities}) => Trip(
      id: id,
      title: title,
      startDate: _rel(10),
      endDate: _rel(20),
      cities: cities,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpList(WidgetTester tester, List<Trip> trips) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripsListScreen()),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('card headlines the trip title with cities as a subtitle line',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _trip('t1', 'Big Summer Adventure 2026',
          cities: ['Prague', 'Kraków', 'Berlin', 'Quito']),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Big Summer Adventure 2026'), findsOneWidget);
    expect(find.text('Prague & Kraków +2 more'), findsOneWidget);

    // The title sits above the cities line, not the other way around.
    expect(
      tester.getTopLeft(find.text('Big Summer Adventure 2026')).dy,
      lessThan(tester.getTopLeft(find.text('Prague & Kraków +2 more')).dy),
    );
  });

  testWidgets('legacy AI-summary title falls back to cities, undoubled',
      (WidgetTester tester) async {
    final longTitle =
        'A 37-day trip across Latin America and Europe with food, nightlife, '
        'nature, and architecture at every stop.';
    await _pumpList(tester, [
      _trip('t1', longTitle, cities: ['Prague', 'Kraków', 'Berlin']),
    ]);
    await tester.pumpAndSettle();

    // The cities label is the headline exactly once — no duplicate subtitle.
    expect(find.text('Prague & Kraków +1 more'), findsOneWidget);
    expect(find.text(longTitle), findsNothing);
  });

  testWidgets('trip without cities shows just the title',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _trip('t1', 'Solo Weekend'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Solo Weekend'), findsOneWidget);
  });

  testWidgets('live trip card headlines the real title too',
      (WidgetTester tester) async {
    final trip = Trip(
      id: 't1',
      title: 'Big Summer Adventure 2026',
      startDate: _rel(-1),
      endDate: _rel(1),
      cities: const ['Prague', 'Kraków', 'Berlin'],
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );
    await tester.pumpWidget(
      // The hero carries a TripMapBand now, which reads the trip cache — so
      // even a bare card pump needs the scope (the band collapses on the
      // miss).
      ProviderScope(
        overrides: [tripCacheProvider.overrideWithValue(TripCache('u1'))],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: Scaffold(body: LiveTripCard(trip: trip, onTap: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Big Summer Adventure 2026'), findsOneWidget);
    // The cities label is the SUBTITLE line, never the headline — the hero
    // gained that line when it took over the plain card's facts, so the
    // assertion is about where it sits, not whether it exists.
    expect(find.text('Prague & Kraków +1 more'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Big Summer Adventure 2026')).dy,
      lessThan(tester.getTopLeft(find.text('Prague & Kraków +1 more')).dy),
    );
  });
}
