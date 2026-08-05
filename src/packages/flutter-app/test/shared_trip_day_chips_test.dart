import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/shared_trip.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/shared_trip_screen.dart';
import 'package:travel_route_planner/widgets/map_day_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final SharedTrip shared;
  _FakeTripsApiService(this.shared) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<SharedTrip> getSharedTrip(String token) async => shared;
}

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
  final shared = SharedTrip(
    ownerName: 'Ann',
    trip: Trip(
      id: 't1',
      title: 'Paris getaway',
      status: 'planned',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-02',
      items: [
        _item(0, 'Louvre', 48.8606, 2.3376, 1),
        _item(1, 'Orsay', 48.8600, 2.3266, 1),
        _item(2, 'Pantheon', 48.8462, 2.3464, 2),
      ],
      accommodations: const [
        // Night of day 1 only (checkout-exclusive).
        Accommodation(
          id: 'a1',
          name: 'Night One Hotel',
          latitude: 48.8630,
          longitude: 2.3364,
          checkIn: '2026-09-01',
          checkOut: '2026-09-02',
        ),
        // Night of day 2 only.
        Accommodation(
          id: 'a2',
          name: 'Night Two Flat',
          latitude: 48.8520,
          longitude: 2.3330,
          checkIn: '2026-09-02',
          checkOut: '2026-09-03',
        ),
      ],
    ),
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_FakeTripsApiService(shared)),
        ],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: SharedTripScreen(token: 'tok')),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Scoped to MapDayChips: the shared list renders its own "Day N" chips on
  /// item tiles.
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

  testWidgets('shared view gets the chip row, defaulting to All',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    final chips = find.byType(MapDayChips);
    expect(chips, findsOneWidget);
    for (final label in ['All', 'Day 1', 'Day 2']) {
      expect(
        find.descendant(of: chips, matching: find.text(label)),
        findsOneWidget,
      );
    }

    // Defaults to All (no Today preselection on shared views).
    expect(map(tester).fitSignature, isNull);
    expect(map(tester).items, hasLength(3));
    expect(map(tester).accommodations, hasLength(2));

    // Both days plot something, so no chip is muted — and the read-only map
    // carries no empty-state CTA.
    expect(tester.widget<MapDayChips>(chips).mappedDays, {1, 2});
    expect(map(tester).emptyAction, isNull);

    // Shared views are viewer-agnostic: never a home-airport overlay.
    expect(map(tester).home, isNull);
  });

  testWidgets('day chip filters the shared map; All restores',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    await tapChip(tester, 'Day 2');

    expect(map(tester).items.map((i) => i.name), ['Pantheon']);
    expect(map(tester).accommodations.map((a) => a.name), ['Night Two Flat']);
    expect(map(tester).fitSignature, 2);

    await tapChip(tester, 'All');

    expect(map(tester).items, hasLength(3));
    expect(map(tester).accommodations, hasLength(2));
  });
}
