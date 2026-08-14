import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

/// Home-airport legs on the INLINE trip-detail map card: the overlay follows
/// the same leg gating as the full-screen map (outbound on All / the first
/// leg, return on All / the last leg, nothing mid-trip), keyed off the
/// viewer's saved home airport. The default test surface (800x600) takes the
/// wide pinned-card path, the surface the legs were invisible on before this
/// feature.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// First getPreferences call fails transiently; later calls return EWR. The
/// A4 regression fixture: a prefs value that lands only after the first
/// build must reach the map through the screen's own guarded setState, not
/// an incidental rebuild from an unrelated code path.
class _QueuedPrefsApi implements PreferencesApiService {
  int calls = 0;

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async {
    calls++;
    if (calls == 1) {
      throw ApiException(
          statusCode: 429, message: 'rate limited', endpoint: '/preferences');
    }
    return const TravelerPreferences(homeAirport: 'EWR');
  }

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
  }) async =>
      const TravelerPreferences(homeAirport: 'EWR');
}

class _FakePrefsApi implements PreferencesApiService {
  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async =>
      const TravelerPreferences(homeAirport: 'EWR');

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
  }) async =>
      const TravelerPreferences(homeAirport: 'EWR');
}

ItineraryItem _item(
  int pos,
  String name,
  String city,
  double lat,
  double lng,
  int day,
) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: city,
    );

void main() {
  // Newark; far from the European fixtures, same point the full-screen
  // tests use.
  const homePoint = (lat: 40.6895, lng: -74.1745);

  // Three legs so the gate has a first, a middle, and a last.
  Trip makeTrip({String? travelMode, String? origin}) => Trip(
    id: 't1',
    title: 'Grand tour',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    startDate: '2026-09-01',
    endDate: '2026-09-03',
    travelMode: travelMode,
    origin: origin,
    items: [
      _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
      _item(1, 'Colosseum', 'Rome', 41.8902, 12.4922, 2),
      _item(2, 'Brandenburg Gate', 'Berlin', 52.5163, 13.3777, 3),
    ],
    accommodations: const [
      Accommodation(
        id: 'a1',
        name: 'Night One Hotel',
        latitude: 48.8630,
        longitude: 2.3364,
        checkIn: '2026-09-01',
        checkOut: '2026-09-02',
      ),
    ],
  );

  final trip = makeTrip();

  Future<void> pumpScreen(
    WidgetTester tester, {
    bool withHome = true,
    Trip? tripOverride,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_FakeTripsApiService(tripOverride ?? trip)),
          if (withHome) ...[
            // Populates _homeAirport via the screen's prefs load...
            preferencesApiServiceProvider.overrideWithValue(_FakePrefsApi()),
            // ...and resolves the IATA to coordinates without the network.
            homeAirportPointProvider('EWR')
                .overrideWith((ref) async => homePoint),
          ],
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Scoped to MapLegChips: the itinerary list renders the same city names
  /// as group headers.
  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(MapLegChips),
      matching: find.text(label),
    ));
    // Settles the camera re-fit and the focus-driven page scroll.
    await tester.pumpAndSettle();
  }

  TripMap map(WidgetTester tester) =>
      tester.widget<TripMap>(find.byType(TripMap));

  testWidgets('All draws both legs, the home pin, and the EWR label',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    final home = map(tester).home;
    expect(home, isNotNull);
    expect(home!.label, 'EWR');
    expect(home.point, LatLng(homePoint.lat, homePoint.lng));
    expect(home.outboundTo, isNotNull);
    expect(home.returnFrom, isNotNull);
    expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('endpoint legs keep their home leg; mid-trip legs get none',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    await tapChip(tester, 'Paris');
    var home = map(tester).home;
    expect(home!.outboundTo, isNotNull);
    expect(home.returnFrom, isNull);

    await tapChip(tester, 'Rome');
    expect(map(tester).home, isNull);
    expect(find.byIcon(Icons.flight_takeoff), findsNothing);

    await tapChip(tester, 'Berlin');
    home = map(tester).home;
    expect(home!.outboundTo, isNull);
    expect(home.returnFrom, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stated ground trip draws no home-airport leg',
      (WidgetTester tester) async {
    // A saved home *airport* says where this traveler flies from, so on a
    // driving trip it is not the origin — drawing a leg from it invents a
    // journey the trip never described (a Claude-authored road trip to
    // Montreal rendered as a flight from Newark, 2026-08-14).
    await pumpScreen(tester, tripOverride: makeTrip(travelMode: 'car'));

    expect(map(tester).home, isNull);
    expect(find.byIcon(Icons.flight_takeoff), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stated origin draws no home-airport leg',
      (WidgetTester tester) async {
    // The trip named where it starts, so the saved airport is known to be the
    // wrong origin — and the stated one is free text we hold no coordinates
    // for. The booking legs still carry it by name.
    await pumpScreen(tester,
        tripOverride: makeTrip(origin: 'Lake George, NY'));

    expect(map(tester).home, isNull);
    expect(find.byIcon(Icons.flight_takeoff), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mixed-mode trip keeps its home leg',
      (WidgetTester tester) async {
    // 'mixed' means the trip has no single mode, so a flight leg is still
    // plausible — only a stated ground mode suppresses the overlay.
    await pumpScreen(tester, tripOverride: makeTrip(travelMode: 'mixed'));

    expect(map(tester).home, isNotNull);
    expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);
  });

  testWidgets('no saved home airport never touches the provider',
      (WidgetTester tester) async {
    // No homeAirportPointProvider override registered: a provider read would
    // throw in this scope if the lookup path were exercised.
    await pumpScreen(tester, withHome: false);

    expect(map(tester).home, isNull);
    expect(find.byIcon(Icons.flight_takeoff), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'prefs failing on boot and succeeding on a quiet refresh still reach '
      'the map (guarded setState, not an incidental rebuild)',
      (WidgetTester tester) async {
    final prefsApi = _QueuedPrefsApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          preferencesApiServiceProvider.overrideWithValue(prefsApi),
          homeAirportPointProvider('EWR')
              .overrideWith((ref) async => homePoint),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Boot: the prefs fetch 429'd — no home overlay yet.
    expect(map(tester).home, isNull);

    // Quiet refresh (drive RefreshIndicator.onRefresh directly — the fling
    // path is covered by the offline tests; over the pinned map card the
    // gesture is unreliable): loadIfNeeded retries the still-null prefs and
    // succeeds; the change-guarded setState must rebuild the map. On the
    // quiet path there is no incidental full-screen setState to hide behind.
    final indicator =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await indicator.onRefresh();
    await tester.pumpAndSettle();

    expect(prefsApi.calls, 2);
    expect(map(tester).home, isNotNull);
    expect(map(tester).home!.label, 'EWR');
    expect(tester.takeException(), isNull);
  });
}
