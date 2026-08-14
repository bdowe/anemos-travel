import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/city_pin.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/shared_with_me_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/section_header.dart';
import 'package:travel_route_planner/widgets/stat_tile_row.dart';
import 'package:travel_route_planner/widgets/travel_footprint_card.dart';

import 'support/l10n_test_app.dart';

/// The "Your travels" section on the trips list (specs/trips-page-insights):
/// the lifetime stat tiles plus the footprint map, gated at 2+ OWNED trips —
/// shared-with-me is someone else's travel and carries none of the fields.
/// The map sub-band is gated separately on having pins; with none the card
/// degrades to a bare stats strip rather than showing an empty globe.
///
/// The "Your travels" title is a page-level SectionHeader ABOVE the card, not
/// inside it — an unlabeled map over a stats panel is the "Up next" hero's
/// silhouette, so an in-card label let the whole thing read as another
/// upcoming trip. Header and card share one gate, so neither renders alone.
///
/// Dates are relative to DateTime.now() so the all-time totals stay
/// deterministic. Tile HTTP in widget tests 400s and is silently tolerated,
/// so map assertions are structural (FlutterMap presence), never imagery.
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;

  _FixedTripsApiService(this.trips) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => trips;
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Trip _trip(String id, String title,
        {String? start,
        String? end,
        List<String>? cities,
        List<CityPin>? pins,
        String? access}) =>
    Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      cities: cities,
      cityPins: pins,
      access: access,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpList(
  WidgetTester tester, {
  List<Trip> trips = const [],
  List<Trip> shared = const [],
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
        sharedWithMeProvider.overrideWith((ref) async => shared),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripsListScreen()),
    ),
  );
}

/// Scopes a finder to the band, so a tile value can't be satisfied by a
/// number printed on a trip card elsewhere on the page.
Finder _inBand(Finder matching) => find.descendant(
    of: find.byType(TravelFootprintCard), matching: matching);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('two owned trips raise the band, map and all',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip',
          start: _rel(10),
          end: _rel(13),
          cities: const ['Lisbon'],
          pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
      _trip('t2', 'Athens Trip',
          start: _rel(40),
          end: _rel(45),
          cities: const ['Athens'],
          pins: const [CityPin(city: 'Athens', lat: 37.9, lng: 23.7)]),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsOneWidget);
    expect(find.text('Your travels'), findsOneWidget);
    expect(_inBand(find.byType(FlutterMap)), findsOneWidget);
    expect(_inBand(find.byType(StatTileRow)), findsOneWidget);
    // The label sits ABOVE the card as a page-level section header, never
    // inside it: an in-card label under the map is what let this read as
    // another upcoming trip card.
    expect(_inBand(find.text('Your travels')), findsNothing);
    // ...and it renders as a peer of "Upcoming", not as card chrome.
    expect(
      find.ancestor(
          of: find.text('Your travels'), matching: find.byType(SectionHeader)),
      findsOneWidget,
    );
  });

  testWidgets('one owned trip gets no band — even beside a shared trip',
      (WidgetTester tester) async {
    // The gate counts OWNED trips: a lifetime aggregate of one trip only
    // restates the hero above it, and shared rows carry no insight fields.
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip',
          start: _rel(10),
          end: _rel(13),
          pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
    ], shared: [
      _trip('s1', 'Shared Trip',
          start: _rel(20), end: _rel(23), access: 'editor'),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsNothing);
    expect(find.text('Your travels'), findsNothing);
    expect(find.text('Shared Trip'), findsOneWidget);
  });

  testWidgets('a shared-only account gets no band',
      (WidgetTester tester) async {
    await _pumpList(tester, shared: [
      _trip('s1', 'Shared Trip',
          start: _rel(10), end: _rel(13), access: 'editor'),
      _trip('s2', 'Other Shared Trip',
          start: _rel(20), end: _rel(23), access: 'editor'),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsNothing);
    expect(find.text('Your travels'), findsNothing);
  });

  testWidgets('pin-less trips collapse the map but keep the header and tiles',
      (WidgetTester tester) async {
    // Old server, or trips whose items are all unlocated: coordinates are
    // never invented, so the card degrades to a bare stats strip. The section
    // header is a sibling above it, so the tiles stay labeled either way —
    // one of the reasons the label moved out of the card.
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip',
          start: _rel(10), end: _rel(13), cities: const ['Lisbon']),
      _trip('t2', 'Athens Trip',
          start: _rel(40), end: _rel(45), cities: const ['Athens']),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsOneWidget);
    expect(find.text('Your travels'), findsOneWidget);
    expect(_inBand(find.byType(StatTileRow)), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
  });

  testWidgets('the tiles are all-time — a finished trip counts',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      // 5 travel days, long over.
      _trip('past', 'Iberia Loop',
          start: _rel(-30), end: _rel(-26), cities: const ['Lisbon', 'Porto']),
      // 3 travel days, still ahead.
      _trip('next', 'Madrid Trip',
          start: _rel(10), end: _rel(12), cities: const ['Madrid']),
    ]);
    await tester.pumpAndSettle();

    expect(_inBand(find.text('2')), findsOneWidget);
    expect(_inBand(find.text('Trips')), findsOneWidget);
    expect(_inBand(find.text('8')), findsOneWidget);
    expect(_inBand(find.text('Travel days')), findsOneWidget);
    expect(_inBand(find.text('3')), findsOneWidget);
    expect(_inBand(find.text('Cities')), findsOneWidget);
  });

  testWidgets('zero-valued segments drop out; the trips tile always stays',
      (WidgetTester tester) async {
    // Undated, city-less legacy rows contribute no days and no cities.
    await _pumpList(tester, trips: [
      _trip('d1', 'Someday Trip'),
      _trip('d2', 'Another Someday'),
    ]);
    await tester.pumpAndSettle();

    expect(_inBand(find.text('2')), findsOneWidget);
    expect(_inBand(find.text('Trips')), findsOneWidget);
    expect(find.text('Travel days'), findsNothing);
    expect(find.text('Cities'), findsNothing);
  });
}
