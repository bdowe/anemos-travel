import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/shared_trip.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/shared_trip_screen.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

// The map-visibility gate must count geocoded stays, not just items: a trip
// whose only mapped things are its accommodations (hotels booked, no located
// activities yet) still has a map worth showing — TripMap renders and
// camera-fits stay pins on its own.

class _FakeTripsApiService extends TripsApiService {
  final Trip? trip;
  final SharedTrip? shared;
  _FakeTripsApiService({this.trip, this.shared})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip!;

  @override
  Future<SharedTrip> getSharedTrip(String token) async => shared!;
}

Trip _trip({List<ItineraryItem>? items, List<Accommodation>? stays}) => Trip(
      id: 't1',
      title: 'Lisbon long weekend',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: items ?? const [],
      accommodations: stays,
    );

const _geocodedStay = Accommodation(
  id: 'a1',
  name: 'Alfama Guesthouse',
  latitude: 38.7139,
  longitude: -9.1334,
);

// null coordinates = "not geocoded"; must not count toward the gate.
const _ungeocodedStay = Accommodation(id: 'a2', name: 'Mystery Hotel');

// (0,0) is the "no location" sentinel for items.
ItineraryItem _unmappedItem(int pos) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: 'Stop $pos',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
    );

Future<void> _pumpTripDetail(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(_FakeTripsApiService(trip: trip)),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSharedTrip(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(
            shared: SharedTrip(trip: trip, ownerName: 'Ann'))),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: SharedTripScreen(token: 'tok')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('trip detail shows the map for a stays-only trip',
      (tester) async {
    await _pumpTripDetail(tester, _trip(stays: const [_geocodedStay]));
    expect(find.byType(TripMap), findsOneWidget);
  });

  testWidgets('trip detail hides the map when nothing has coordinates',
      (tester) async {
    await _pumpTripDetail(
      tester,
      _trip(
        items: [_unmappedItem(0), _unmappedItem(1)],
        stays: const [_ungeocodedStay],
      ),
    );
    expect(find.byType(TripMap), findsNothing);
  });

  testWidgets('shared trip shows the map for a stays-only trip',
      (tester) async {
    await _pumpSharedTrip(tester, _trip(stays: const [_geocodedStay]));
    expect(find.byType(TripMap), findsOneWidget);
  });

  testWidgets('shared trip hides the map when nothing has coordinates',
      (tester) async {
    await _pumpSharedTrip(
      tester,
      _trip(
        items: [_unmappedItem(0), _unmappedItem(1)],
        stays: const [_ungeocodedStay],
      ),
    );
    expect(find.byType(TripMap), findsNothing);
  });
}
