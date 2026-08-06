import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

ItineraryItem _item(int pos, String name, String city, int day) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name street, $city-land',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

void main() {
  testWidgets('city and day headers pin while scrolling, then are pushed off',
      (WidgetTester tester) async {
    // No startDate, so day headers read "Day N" and no date ranges render.
    final trip = Trip(
      id: 't1',
      title: 'Two cities',
      status: 'planned',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        // Paris: a short day 1 and a long day 2, so mid-scroll positions
        // land inside day 2 while still inside the Paris group.
        _item(0, 'Louvre', 'Paris', 1),
        _item(1, 'Orsay', 'Paris', 1),
        for (var k = 0; k < 6; k++) _item(2 + k, 'Paris stop $k', 'Paris', 2),
        // Rome needs enough content that scrolling can carry its header all
        // the way up to the pinned slot, fully pushing Paris off.
        for (var k = 0; k < 4; k++) _item(8 + k, 'Rome stop $k', 'Rome', 3),
        for (var k = 0; k < 4; k++)
          _item(12 + k, 'Rome day4 stop $k', 'Rome', 4),
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

    // Groups default collapsed — open both so scrolling has content. Rome
    // first: while everything is collapsed both headers sit in the viewport,
    // whereas expanding Paris first would push Rome's header below the fold
    // and the tap would miss.
    await expandCity(tester, 'Rome');
    await expandCity(tester, 'Paris');

    expect(find.text('Paris'), findsOneWidget);

    // Scroll into the middle of Paris day 2, far enough that both the city
    // and day headers have reached their pinned slots. jumpTo keeps offsets
    // exact (drag gestures fling unpredictably past the target).
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    position.jumpTo(550);
    await tester.pumpAndSettle();

    final parisDyA = tester.getTopLeft(find.text('Paris')).dy;
    final day2DyA = tester.getTopLeft(find.text('Day 2')).dy;
    final stopDyA = tester.getTopLeft(find.text('Paris stop 4')).dy;

    // Scroll a bit further, still within Paris day 2: the pinned city and
    // day headers hold their position while the items keep moving.
    position.jumpTo(700);
    await tester.pumpAndSettle();

    expect(
        tester.getTopLeft(find.text('Paris')).dy, moreOrLessEquals(parisDyA));
    expect(tester.getTopLeft(find.text('Day 2')).dy, moreOrLessEquals(day2DyA));
    expect(tester.getTopLeft(find.text('Paris stop 4')).dy,
        moreOrLessEquals(stopDyA - 150));
    // Pinned headers sit on screen, day header below the city header.
    expect(parisDyA, greaterThan(0));
    expect(day2DyA, greaterThan(parisDyA));

    // Scroll to the bottom: Rome takes over the pinned city slot, pushing
    // the Paris and Day 2 headers off.
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(find.text('Rome'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Rome')).dy, moreOrLessEquals(parisDyA));
    expect(tester.getTopLeft(find.text('Day 4')).dy, greaterThan(parisDyA));
    final parisAfter = find.text('Paris');
    if (parisAfter.evaluate().isNotEmpty) {
      // Still built within the cache extent, but scrolled above Rome.
      expect(tester.getTopLeft(parisAfter).dy, lessThan(parisDyA));
    }
  });
}
