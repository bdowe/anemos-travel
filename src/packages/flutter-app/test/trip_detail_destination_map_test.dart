import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';

import 'support/chip_finders.dart';
import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
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
      city: city,
      day: day,
    );

void main() {
  // Two cities so the All view crosses TripMap's ≥2-destination gate; the
  // single-city fixtures in the other trip-detail tests deliberately never do.
  final trip = Trip(
    id: 't1',
    title: 'Paris & Rome',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    startDate: '2026-09-01',
    endDate: '2026-09-02',
    items: [
      _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
      _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 1),
      _item(2, 'Colosseum', 'Rome', 41.8902, 12.4922, 2),
    ],
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(MapLegChips),
      matching: find.text(label),
    ));
    // Settles the camera re-fit and the focus-driven page scroll.
    await tester.pumpAndSettle();
  }

  /// Pin labels scoped to the map — the itinerary list renders its own text.
  Finder inMap(String text) =>
      find.descendant(of: find.byType(FlutterMap), matching: find.text(text));

  testWidgets(
      'All numbers destinations 1..N in visit order; a city focus flips to '
      'per-stop pins and back', (WidgetTester tester) async {
    await pumpScreen(tester);

    // All: one pin per city, no clusterer — three items, two pins.
    expect(find.byType(MarkerClusterLayerWidget), findsNothing);
    expect(inMap('1'), findsOneWidget);
    expect(inMap('2'), findsOneWidget);
    expect(inMap('3'), findsNothing);

    // Pin 2 is the second *destination* (Rome), not the second item.
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: inMap('2'), matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, startsWith('Rome'));

    // Focusing Paris: per-item stop pins return, inside the clusterer.
    await tapChip(tester, 'Paris');
    expect(find.byType(MarkerClusterLayerWidget), findsOneWidget);
    expect(inMap('1'), findsOneWidget);
    expect(inMap('2'), findsOneWidget);

    // The reset restores the overview.
    await tapMapReset(tester);
    expect(find.byType(MarkerClusterLayerWidget), findsNothing);
    expect(inMap('1'), findsOneWidget);
    expect(inMap('2'), findsOneWidget);
    expect(inMap('3'), findsNothing);
  });
}
