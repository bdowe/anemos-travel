import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/shared_trip.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/shared_trip_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/map_day_chips.dart';
import 'package:travel_route_planner/widgets/section_header.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final SharedTrip shared;
  _FakeTripsApiService(this.shared) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<SharedTrip> getSharedTrip(String token) async => shared;
}

ItineraryItem _item(
  int pos,
  String name, {
  String? city,
  String? address,
  double lat = 0,
  double lng = 0,
  int? day,
}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      city: city,
      address: address,
      day: day,
    );

SharedTrip _shared(List<ItineraryItem> items) => SharedTrip(
      ownerName: 'Ann',
      trip: Trip(
        id: 't1',
        title: 'Grand tour',
        status: 'planned',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        startDate: '2026-09-01',
        endDate: '2026-09-03',
        items: items,
      ),
    );

void main() {
  Future<void> pumpScreen(WidgetTester tester, SharedTrip shared) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_FakeTripsApiService(shared)),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: SharedTripScreen(token: 'tok'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Pin labels scoped to the map — the shared list numbers its own tiles.
  Finder inMap(String text) =>
      find.descendant(of: find.byType(FlutterMap), matching: find.text(text));

  testWidgets(
      'All shows destination pins with ungeocoded legs skipped (numbering '
      'stays contiguous); a day chip flips to item pins',
      (WidgetTester tester) async {
    await pumpScreen(
      tester,
      _shared([
        _item(0, 'Louvre', city: 'Paris', lat: 48.8606, lng: 2.3376, day: 1),
        // Whole leg ungeocoded: pinless, and it must not consume a number.
        _item(1, 'Traboules', city: 'Lyon', day: 2),
        _item(2, 'Colosseum', city: 'Rome', lat: 41.8902, lng: 12.4922, day: 3),
      ]),
    );

    expect(find.byType(MarkerClusterLayerWidget), findsNothing);
    expect(inMap('1'), findsOneWidget);
    expect(inMap('2'), findsOneWidget);
    expect(inMap('3'), findsNothing);

    // Pin 2 skips pinless Lyon and lands on Rome, label-only (the shared
    // view has no owner-side date allocation).
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: inMap('2'), matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, 'Rome');

    // Day 1: per-item pins return.
    await tester.tap(find.descendant(
      of: find.byType(MapDayChips),
      matching: find.text('Day 1'),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byType(MarkerClusterLayerWidget), findsOneWidget);
    expect(inMap('1'), findsOneWidget);
  });

  testWidgets(
      'a null-city item with a parseable address groups under the parsed city '
      '(owner-view parity)', (WidgetTester tester) async {
    await pumpScreen(
      tester,
      _shared([
        _item(0, 'Louvre', city: 'Paris', lat: 48.8606, lng: 2.3376),
        _item(1, 'Bouchon Daniel', address: 'Rue X, 69001 Lyon, France'),
      ]),
    );

    // Before the shared tripLegs delegation this fell into the localized
    // "Places" bucket; now it groups under the address-parsed city, exactly
    // like the owner's trip detail.
    expect(
      find.descendant(
        of: find.byType(SectionHeader),
        matching: find.text('Lyon'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a revisited city renders two separate groups',
      (WidgetTester tester) async {
    await pumpScreen(
      tester,
      _shared([
        _item(0, 'Louvre', city: 'Paris', lat: 48.8606, lng: 2.3376),
        _item(1, 'Colosseum', city: 'Rome', lat: 41.8902, lng: 12.4922),
        _item(2, 'Orsay', city: 'Paris', lat: 48.8600, lng: 2.3266),
      ]),
    );

    expect(
      find.descendant(
        of: find.byType(SectionHeader),
        matching: find.text('Paris'),
      ),
      findsNWidgets(2),
    );
    // And on the map: three destination pins, the revisit numbered last.
    expect(inMap('3'), findsOneWidget);
  });
}
