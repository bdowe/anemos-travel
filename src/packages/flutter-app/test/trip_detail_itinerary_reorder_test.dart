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

ItineraryItem _item(int pos, String name, String category,
        {int? day, String? city, String? dayTripFrom}) =>
    ItineraryItem(
      id: 'i-$name',
      position: pos,
      name: name,
      address: '$name address',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: category,
      day: day,
      city: city,
      dayTripFrom: dayTripFrom,
    );

Trip _tripWith(List<ItineraryItem> items) => Trip(
      id: 't1',
      title: 'Paris',
      startDate: '2026-09-01',
      endDate: '2026-09-03',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items,
    );

/// Serves the seeded trip and mirrors the server's reorder: a successful
/// PUT /items/order call re-sorts the served items, so the screen's silent
/// reload after a drag sees the new order (a failing call leaves it stale,
/// so the reload restores the original order — the revert path).
class _FakeTripsApiService extends TripsApiService {
  List<ItineraryItem> items;
  final List<List<String>> reorderCalls = [];
  final bool failReorder;
  _FakeTripsApiService(Trip trip, {this.failReorder = false})
      : items = trip.items!,
        super(ApiClient(baseUrl: 'http://test'));

  // A fresh list per fetch, like a real JSON parse — the screen's optimistic
  // in-place reorder must never alias the "server's" copy.
  @override
  Future<Trip> getTrip(String id) async => _tripWith(List.of(items));

  @override
  Future<void> reorderItineraryItems(String tripId, List<String> itemIds) async {
    reorderCalls.add(itemIds);
    if (failReorder) throw Exception('server said no');
    final byId = {for (final it in items) it.id: it};
    items = [for (final id in itemIds) byId[id]!];
  }
}

/// Item rows render inside lazy SliverReorderableLists; a tall viewport keeps
/// the whole itinerary built and findable.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<_FakeTripsApiService> _pump(WidgetTester tester, Trip trip,
    {bool failReorder = false}) async {
  final fake = _FakeTripsApiService(trip, failReorder: failReorder);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tripsApiServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

/// Drags the handle inside [name]'s ListTile vertically by [dy].
Future<void> _dragItem(WidgetTester tester, String name, double dy) async {
  final row =
      find.ancestor(of: find.text(name), matching: find.byType(ListTile));
  final handle =
      find.descendant(of: row, matching: find.byIcon(Icons.drag_indicator));
  final gesture = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 100));
  for (var i = 0; i < 5; i++) {
    await gesture.moveBy(Offset(0, dy / 5));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

double _rowTop(WidgetTester tester, String name) => tester
    .getTopLeft(find.ancestor(of: find.text(name), matching: find.byType(ListTile)))
    .dy;

void main() {
  testWidgets('inline drag reorders within a day and sends the full permutation',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
        _item(2, 'Le Comptoir', 'restaurant', day: 1, city: 'Paris'),
        _item(3, 'Pantheon', 'attraction', day: 2, city: 'Paris'),
        _item(4, 'Sorbonne', 'attraction', day: 2, city: 'Paris'),
      ]),
    );

    // A handle on every row: 3 in day 1's batch + 2 in day 2's.
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(5));

    final rowHeight = _rowTop(tester, 'Orsay') - _rowTop(tester, 'Louvre');
    await _dragItem(tester, 'Louvre', rowHeight + 20);

    expect(fake.reorderCalls, [
      ['i-Orsay', 'i-Louvre', 'i-Le Comptoir', 'i-Pantheon', 'i-Sorbonne']
    ]);
    expect(_rowTop(tester, 'Orsay'), lessThan(_rowTop(tester, 'Louvre')));
    expect(_rowTop(tester, 'Louvre'), lessThan(_rowTop(tester, 'Le Comptoir')));
    // Day 2 untouched.
    expect(_rowTop(tester, 'Pantheon'), lessThan(_rowTop(tester, 'Sorbonne')));
  });

  testWidgets('day-trip batches drag independently of the hub batch',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
        _item(2, 'Chateau', 'attraction',
            day: 1, city: 'Versailles', dayTripFrom: 'Paris'),
        _item(3, 'Gardens', 'attraction',
            day: 1, city: 'Versailles', dayTripFrom: 'Paris'),
      ]),
    );

    expect(find.text('Day trip · Versailles'), findsOneWidget);

    final rowHeight = _rowTop(tester, 'Gardens') - _rowTop(tester, 'Chateau');
    await _dragItem(tester, 'Chateau', rowHeight + 20);

    // The day-trip drag permutes only the batch's slots.
    expect(fake.reorderCalls, [
      ['i-Louvre', 'i-Orsay', 'i-Gardens', 'i-Chateau']
    ]);
    expect(_rowTop(tester, 'Gardens'), lessThan(_rowTop(tester, 'Chateau')));
    // Hub order untouched.
    expect(_rowTop(tester, 'Louvre'), lessThan(_rowTop(tester, 'Orsay')));
  });

  testWidgets('failed reorder reverts the order and shows a snackbar',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
      ]),
      failReorder: true,
    );

    final rowHeight = _rowTop(tester, 'Orsay') - _rowTop(tester, 'Louvre');
    await _dragItem(tester, 'Louvre', rowHeight + 20);

    expect(fake.reorderCalls.length, 1);
    // The silent reload restored the server's (unchanged) order.
    expect(_rowTop(tester, 'Louvre'), lessThan(_rowTop(tester, 'Orsay')));
    expect(find.textContaining('Could not reorder'), findsOneWidget);
  });

  testWidgets('a single-item batch gets no drag handle',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
        _item(2, 'Pantheon', 'attraction', day: 2, city: 'Paris'),
      ]),
    );

    // Two handles in day 1, none for day 2's single item.
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    final day2Row = find.ancestor(
        of: find.text('Pantheon'), matching: find.byType(ListTile));
    expect(
        find.descendant(
            of: day2Row, matching: find.byIcon(Icons.drag_indicator)),
        findsNothing);
  });
}
