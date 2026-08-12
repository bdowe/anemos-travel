import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/chip_finders.dart';
import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

ItineraryItem _item(int pos, String name, String address, String category,
        {int? day, String? city, String? dayTripFrom}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: address,
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: category,
      day: day,
      city: city,
      dayTripFrom: dayTripFrom,
    );

/// Item rows now render inside lazy SliverReorderableLists, so rows below the
/// default 800x600 viewport (plus cache extent) are never built. A tall
/// viewport keeps the whole itinerary built and findable.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('itinerary groups by locality with dates derived from a stay',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final trip = Trip(
      id: 't1',
      title: 'Bahamas',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, "Brendal's Dive Center", 'Green Turtle Cay, Abaco, Bahamas', 'attraction', city: 'Green Turtle Cay'),
        _item(1, "Miss Emily's Blue Bee Bar", 'Green Turtle Cay, Abaco, Bahamas', 'restaurant', city: 'Green Turtle Cay'),
        _item(2, 'Dive Guana', 'Great Guana Cay, Abaco, Bahamas', 'attraction', city: 'Great Guana Cay'),
        _item(3, "Nipper's Beach Bar", 'Great Guana Cay, Abaco, Bahamas', 'restaurant', city: 'Great Guana Cay'),
      ],
      // A stay in Green Turtle Cay supplies that group's dates; Great Guana has none.
      accommodations: const [
        Accommodation(
          id: 'a1',
          name: 'Green Turtle Club',
          address: 'Green Turtle Cay, Abaco, Bahamas',
          checkIn: '2026-06-10',
          checkOut: '2026-06-12',
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Two locality headers appear.
    expect(find.text('Green Turtle Cay'), findsOneWidget);
    expect(find.text('Great Guana Cay'), findsOneWidget);

    // The Green Turtle Cay group is labelled with the stay's date range
    // plus its night count.
    expect(chipTextIn('Green Turtle Cay', 'Jun 10 – Jun 12'), findsOneWidget);
    expect(chipTextIn('Green Turtle Cay', '· 2 nights'), findsOneWidget);

    // Groups default collapsed and at most ONE is open at a time (accordion):
    // expanding a city closes the previously open one. Assert each group's
    // body while that group is the open one.
    await expandCity(tester, 'Green Turtle Cay');
    expect(find.text("Brendal's Dive Center"), findsOneWidget);
    // Legacy items (no day) render with no "Day N" sub-headers.
    expect(find.textContaining('Day 1'), findsNothing);

    // Opening Great Guana Cay collapses Green Turtle Cay.
    await expandCity(tester, 'Great Guana Cay');
    expect(find.text('Dive Guana'), findsOneWidget);
    // Legacy rule holds in this group too.
    expect(find.textContaining('Day 1'), findsNothing);
  });

  testWidgets('items with day numbers render Day sub-sections and city dates',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final trip = Trip(
      id: 't2',
      title: 'Europe',
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
        // Day 4 jumps to Rome — day numbers stay continuous across the trip.
        _item(3, 'Colosseum', 'Rome, Italy', 'attraction', day: 4, city: 'Rome'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't2')),
      ),
    );
    await tester.pumpAndSettle();

    // City headers.
    expect(find.text('Paris'), findsOneWidget);
    expect(find.text('Rome'), findsOneWidget);

    // Groups default collapsed and at most ONE is open at a time (accordion):
    // opening Rome would collapse Paris, so each city's day sub-headers are
    // asserted while that city is the open group.
    await expandCity(tester, 'Paris');

    // Day sub-headers show the weekday + date derived from the trip start
    // (day N -> startDate + (N-1)). Jun 10 2026 is a Wednesday.
    expect(find.text('Wed, Jun 10'), findsOneWidget);
    expect(find.text('Thu, Jun 11'), findsOneWidget);

    // Paris spans days 1–2 -> Jun 10 – Jun 11 (1 night) next to the city name.
    // (Chip-level: renders regardless of expansion.)
    expect(chipTextIn('Paris', 'Jun 10 – Jun 11'), findsOneWidget);
    expect(chipTextIn('Paris', '· 1 night'), findsOneWidget);

    // The Versailles day trip still nests under its day (Paris group body).
    expect(find.text('Day trip · Versailles'), findsOneWidget);

    // Opening Rome collapses Paris.
    await expandCity(tester, 'Rome');
    expect(find.text('Sat, Jun 13'), findsOneWidget);
    expect(find.text('Colosseum'), findsOneWidget);
  });
}
