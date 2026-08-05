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
import 'package:travel_route_planner/widgets/map_day_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

/// Home-airport legs on the INLINE trip-detail map card: the overlay follows
/// the same day gating as the full-screen map (outbound on All/Day 1, return
/// on All/last day, nothing mid-trip), keyed off the viewer's saved home
/// airport. The default test surface (800x600) takes the wide pinned-card
/// path, the surface the legs were invisible on before this feature.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
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
  }) async =>
      const TravelerPreferences(homeAirport: 'EWR');
}

/// Real (tight Paris-cluster) coordinates so the trip detail screen mounts a
/// live TripMap instead of skipping it.
ItineraryItem _item(int pos, String name, double lat, double lng, int day) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: 'Paris',
    );

void main() {
  // Newark; far from the Paris fixtures, same point the full-screen tests use.
  const homePoint = (lat: 40.6895, lng: -74.1745);

  // Sept 1–3 => Day 1..3 chips; Day 3 deliberately has nothing mappable, so
  // the return-leg assertion also covers the on-map empty state (TripMap's
  // home is a constructor argument, present whether or not tiles render).
  final trip = Trip(
    id: 't1',
    title: 'Paris',
    status: 'planned',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    startDate: '2026-09-01',
    endDate: '2026-09-03',
    items: [
      _item(0, 'Louvre', 48.8606, 2.3376, 1),
      _item(1, 'Orsay', 48.8600, 2.3266, 1),
      _item(2, 'Pantheon', 48.8462, 2.3464, 2),
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

  Future<void> pumpScreen(WidgetTester tester, {bool withHome = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
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

  /// Scoped to MapDayChips: the itinerary list renders its own "Day N"
  /// headers and an "All" category chip.
  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(MapDayChips),
      matching: find.text(label),
    ));
    await tester.pump();
    await tester.pump(); // post-frame camera re-fit
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

  testWidgets('endpoint days keep their leg; mid-trip days get no overlay',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    await tapChip(tester, 'Day 1');
    var home = map(tester).home;
    expect(home!.outboundTo, isNotNull);
    expect(home.returnFrom, isNull);

    await tapChip(tester, 'Day 2');
    expect(map(tester).home, isNull);
    expect(find.byIcon(Icons.flight_takeoff), findsNothing);

    await tapChip(tester, 'Day 3');
    home = map(tester).home;
    expect(home!.outboundTo, isNull);
    expect(home.returnFrom, isNotNull);
    expect(tester.takeException(), isNull);
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
}
