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
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/chip_finders.dart';
import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final SharedTrip shared;
  _FakeTripsApiService(this.shared) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<SharedTrip> getSharedTrip(String token) async => shared;
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
  // Paris (days 1-2, stay-anchored Sep 1–2) → Rome (day 3, stay-anchored
  // Sep 2–4): both legs geocoded and each with its own covering stay, so the
  // per-leg stay filter has something to split.
  final shared = SharedTrip(
    ownerName: 'Ann',
    trip: Trip(
      id: 't1',
      title: 'Paris getaway',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-03',
      items: [
        _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
        _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        _item(2, 'Colosseum', 'Rome', 41.8902, 12.4922, 3),
      ],
      accommodations: const [
        Accommodation(
          id: 'a1',
          name: 'Night One Hotel',
          address: 'Rue X, Paris',
          latitude: 48.8630,
          longitude: 2.3364,
          checkIn: '2026-09-01',
          checkOut: '2026-09-02',
        ),
        Accommodation(
          id: 'a2',
          name: 'Rome Inn',
          address: 'Via Y, Rome',
          latitude: 41.9000,
          longitude: 12.5000,
          checkIn: '2026-09-02',
          checkOut: '2026-09-04',
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
            localizationsDelegates: testLocalizationsDelegates,
            home: SharedTripScreen(token: 'tok')),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Scoped to MapLegChips: the shared list renders the same city names as
  /// section headers.
  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(MapLegChips),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  TripMap map(WidgetTester tester) =>
      tester.widget<TripMap>(find.byType(TripMap));

  testWidgets('shared view gets the leg chip row, defaulting to the overview',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    final chips = find.byType(MapLegChips);
    expect(chips, findsOneWidget);
    expect(mapResetButton, findsNothing);
    for (final label in ['Paris', 'Rome']) {
      expect(
        find.descendant(of: chips, matching: find.text(label)),
        findsOneWidget,
      );
    }

    // Defaults to All (no Today preselection on shared views).
    expect(map(tester).fitSignature, isNull);
    expect(map(tester).items, hasLength(3));
    expect(map(tester).accommodations, hasLength(2));

    // Both legs plot something, so no chip is muted — and the read-only map
    // carries no empty-state CTA.
    expect(tester.widget<MapLegChips>(chips).mappedLegKeys, {'Paris', 'Rome'});
    expect(map(tester).emptyAction, isNull);

    // Shared views are viewer-agnostic: never a home-airport overlay.
    expect(map(tester).home, isNull);
  });

  testWidgets('a city chip filters the shared map to that leg; All restores',
      (WidgetTester tester) async {
    await pumpScreen(tester);

    await tapChip(tester, 'Rome');

    expect(map(tester).items.map((i) => i.name), ['Colosseum']);
    // Rome is stay-anchored Sep 2–4: only its own stay covers those nights.
    expect(map(tester).accommodations.map((a) => a.name), ['Rome Inn']);
    expect(map(tester).fitSignature, 'Rome');

    await tapMapReset(tester);

    expect(map(tester).items, hasLength(3));
    expect(map(tester).accommodations, hasLength(2));
    expect(map(tester).fitSignature, isNull);
  });
}
