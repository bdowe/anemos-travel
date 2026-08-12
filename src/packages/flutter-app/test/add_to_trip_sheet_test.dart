import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/event.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/local_recommendation.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/add_to_trip_sheet.dart';

import 'support/l10n_test_app.dart';

/// Serves a fixed trip list/detail and captures the add-item POST body, so the
/// test can assert exactly what the picker sends (specs/add-to-itinerary).
class _FakeTripsApiService extends TripsApiService {
  final List<Trip> trips;
  final Trip detail;
  String? addedTripId;
  Map<String, dynamic>? addedBody;

  _FakeTripsApiService({required this.trips, required this.detail})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => trips;

  @override
  Future<Trip> getTrip(String id) async => detail;

  @override
  Future<Trip> addItineraryItem(String tripId, Map<String, dynamic> body) async {
    addedTripId = tripId;
    addedBody = body;
    return detail;
  }
}

const _rec = LocalRecommendation(
  id: 'rec-1',
  name: 'Tasca da Ana',
  city: 'Lisbon',
  category: 'restaurant',
  address: 'Rua do Norte 12',
  placeId: 'place-1',
  latitude: 38.71,
  longitude: -9.14,
  sourceName: 'Ana',
);

Trip _trip({List<ItineraryItem> items = const [], String? start, String? end}) =>
    Trip(
      id: 't1',
      title: 'Lisbon Trip',
      startDate: start,
      endDate: end,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: items,
    );

Widget _harness(_FakeTripsApiService service, AddToTripPayload payload) {
  return ProviderScope(
    overrides: [tripsApiServiceProvider.overrideWithValue(service)],
    child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAddToTripSheet(context, payload),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openAndPickTrip(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Lisbon Trip'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local rec add posts the attribution snapshots',
      (WidgetTester tester) async {
    final existing = ItineraryItem(
        id: 'i0', position: 0, name: 'Castle', latitude: 0, longitude: 0, day: 2);
    final service =
        _FakeTripsApiService(trips: [_trip()], detail: _trip(items: [existing]));

    await tester.pumpWidget(
        _harness(service, AddToTripPayload.fromLocalRec(_rec)));
    await _openAndPickTrip(tester);

    // Day chips come from the trip's tagged items; pick day 2.
    await tester.tap(find.text('Day 2'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add to trip'));
    await tester.pumpAndSettle();

    expect(service.addedTripId, 't1');
    final body = service.addedBody!;
    expect(body['name'], 'Tasca da Ana');
    expect(body['latitude'], 38.71);
    expect(body['longitude'], -9.14);
    expect(body['city'], 'Lisbon');
    expect(body['address'], 'Rua do Norte 12');
    expect(body['place_id'], 'place-1');
    expect(body['category'], 'restaurant');
    expect(body['day'], 2);
    expect(body['local_source_name'], 'Ana');
    expect(body['local_recommendation_id'], 'rec-1');

    // Success snackbar with the view-trip shortcut.
    expect(find.text('Added to Lisbon Trip'), findsOneWidget);
    expect(find.text('View trip'), findsOneWidget);
  });

  testWidgets('adding a rec already on the trip warns but allows',
      (WidgetTester tester) async {
    final dup = ItineraryItem(
      id: 'i0',
      position: 0,
      name: 'Somewhere else',
      latitude: 0,
      longitude: 0,
      localRecommendationId: 'rec-1',
    );
    final service =
        _FakeTripsApiService(trips: [_trip()], detail: _trip(items: [dup]));

    await tester.pumpWidget(
        _harness(service, AddToTripPayload.fromLocalRec(_rec)));
    await _openAndPickTrip(tester);

    expect(find.text('Already on this trip.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add anyway'));
    await tester.pumpAndSettle();

    expect(service.addedBody?['local_recommendation_id'], 'rec-1');
  });

  testWidgets('event add derives day and time-of-day, no snapshots',
      (WidgetTester tester) async {
    const event = Event(
      id: 'e1',
      name: 'Fado Night',
      venue: 'Casa do Fado',
      city: 'Lisbon',
      startDate: '2026-08-12',
      startTime: '19:30',
      latitude: 38.7,
      longitude: -9.1,
    );
    final service = _FakeTripsApiService(
      trips: [_trip()],
      detail: _trip(start: '2026-08-10', end: '2026-08-15'),
    );

    await tester.pumpWidget(
        _harness(service, AddToTripPayload.fromEvent(event)));
    await _openAndPickTrip(tester);

    // Day 3 (Aug 12 on an Aug 10 start) is pre-selected from the event date.
    await tester.tap(find.widgetWithText(FilledButton, 'Add to trip'));
    await tester.pumpAndSettle();

    final body = service.addedBody!;
    expect(body['name'], 'Fado Night');
    expect(body['address'], 'Casa do Fado');
    expect(body['category'], 'attraction');
    expect(body['day'], 3);
    expect(body['time_of_day'], 'evening');
    expect(body.containsKey('local_source_name'), isFalse);
    expect(body.containsKey('local_recommendation_id'), isFalse);
  });
}
