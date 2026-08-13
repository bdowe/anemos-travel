import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
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

/// Nullable category: real AI city fillers often carry none.
ItineraryItem _item(int pos, String name, String address,
        {String? category, int? day, String? city, String? timeOfDay}) =>
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
      timeOfDay: timeOfDay,
    );

/// Item rows now render inside lazy SliverReorderableLists, so rows below the
/// default 800x600 viewport (plus cache extent) are never built. A tall
/// viewport keeps the whole itinerary built and findable.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: trip.id)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('city-filler item is hidden and its day section disappears',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final trip = Trip(
      id: 't1',
      title: 'Europe',
      startDate: '2026-06-10',
      endDate: '2026-06-11',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Prague Castle', 'Prague, Czechia',
            category: 'attraction', day: 1, city: 'Prague'),
        // The AI's "no activities" filler: name is just the city.
        _item(1, 'Prague', 'Prague, Czechia',
            day: 2, city: 'Prague', timeOfDay: 'afternoon'),
      ],
    );

    await _pump(tester, trip);

    // 'Prague' appears once — the city header. The filler tile is gone.
    expect(find.text('Prague'), findsOneWidget);
    expect(find.text('Prague Castle'), findsOneWidget);

    // Day 1 keeps its sub-header; the filler-only day 2 renders no header.
    expect(find.text('Wed, Jun 10'), findsOneWidget);
    expect(find.text('Thu, Jun 11'), findsNothing);
  });

  testWidgets('all-filler city still renders its city header',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final trip = Trip(
      id: 't2',
      title: 'Europe',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Prague Castle', 'Prague, Czechia',
            category: 'attraction', day: 1, city: 'Prague'),
        // Vienna's only item is a filler: the city group (header + booking
        // rows) must survive even though every tile in it is hidden. Pins the
        // filter's placement in _buildGroupItemSlivers, not _filtered.
        _item(1, 'Vienna', 'Vienna, Austria',
            day: 3, city: 'Vienna', timeOfDay: 'afternoon'),
      ],
    );

    await _pump(tester, trip);

    // Groups default EXPANDED, so both cities' bodies render at once — the
    // asserts exercise the filler suppression itself, not collapse (a
    // collapsed Vienna would hide day headers regardless).
    expect(find.text('Prague Castle'), findsOneWidget);

    // Still exactly one 'Vienna': the header. A broken filler filter would
    // render the filler tile as a second one inside the expanded group.
    expect(find.text('Vienna'), findsOneWidget);
    expect(find.text('Fri, Jun 12'), findsNothing);
  });
}
