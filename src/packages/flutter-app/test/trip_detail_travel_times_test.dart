import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/location_timing.dart';
import 'package:travel_route_planner/models/route_request.dart';
import 'package:travel_route_planner/models/route_response.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/api_client_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Serves canned per-leg timings for /optimize-route (preserve-order mode), so
/// the screen's travel-time labels render without a backend.
class _FakeApiClient extends ApiClient {
  final List<int> legMinutes; // travel_to_next per location, by input order
  _FakeApiClient(this.legMinutes) : super(baseUrl: 'http://test');

  @override
  Future<RouteResponse> optimizeRoute(RouteRequest request) async {
    final timings = [
      for (var i = 0; i < request.locations.length; i++)
        LocationTiming(
          location: request.locations[i],
          arrivalTime: '09:00',
          departureTime: '10:00',
          visitDurationMin: 60,
          travelToNextMin: i < legMinutes.length ? legMinutes[i] : 0,
          travelToNextKm: 10,
        ),
    ];
    return RouteResponse(
      optimizedRoute: request.locations,
      totalDistanceKm: 0,
      totalTravelTimeMin: 0,
      totalVisitTimeMin: 0,
      totalTripTimeMin: 0,
      locationTimings: timings,
      algorithm: 'preserve_order',
      locationCount: request.locations.length,
      status: 'success',
    );
  }
}

ItineraryItem _item(int pos, String name, String address, String category,
        {int? day, String? city, String? dayTripFrom}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: address,
      // Nonzero coords so the screen requests travel times.
      latitude: 48.8 + pos,
      longitude: 2.3 + pos,
      category: category,
      day: day,
      city: city,
      dayTripFrom: dayTripFrom,
    );

void main() {
  testWidgets('day-trip sub-header shows travel time from the hub city',
      (WidgetTester tester) async {
    // Tall viewport: with coords present the pinned map takes the top of the
    // screen, and the lazily-built list must reach the day-trip rows.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final trip = Trip(
      id: 't1',
      title: 'Europe',
      status: 'planned',
      startDate: '2026-06-10',
      endDate: '2026-06-14',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', 'Paris, France', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Café de Flore', 'Paris, France', 'restaurant', day: 1, city: 'Paris'),
        // Day 2 in Paris is a day trip to Versailles. (A specific place name —
        // an item named just 'Versailles' would be hidden as a city filler.)
        _item(2, 'Palace of Versailles', 'Versailles, France', 'attraction',
            day: 2, city: 'Versailles', dayTripFrom: 'Paris'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          // Leg 0: Louvre -> Café (12 min); leg 1: Café -> Versailles (45 min).
          apiClientProvider.overrideWithValue(_FakeApiClient([12, 45])),
        ],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Day trip · Versailles'), findsOneWidget);
    // The sub-header carries the hub -> day-trip leg time.
    expect(find.text('45 min from Paris'), findsOneWidget);
  });
}
