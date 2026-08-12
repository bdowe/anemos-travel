// Pins the derivation-memo epoch contract (specs/perf-program, Wave 4 PR1).
//
// `_reorderBatchInline` mutates the trip's item List IN PLACE
// (`items.setAll`) — the one derivation input that changes without an
// identity flip — and must bump `_itemOrderEpoch` inside the same setState so
// the optimistic frame recomputes the city groups and renders the dragged
// order. This test drags, then pumps frames BEFORE the silent reload
// resolves (the fake's getTrip is gated on a Completer): if the epoch bump
// is ever lost, the memoized derivation serves the stale order and the
// assertion fails on the optimistic frame.
//
// Fake + drag mechanics follow test/trip_detail_itinerary_reorder_test.dart.

import 'dart:async';

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

ItineraryItem _item(int pos, String name) => ItineraryItem(
      id: 'i-$name',
      position: pos,
      name: name,
      address: '$name address',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: 1,
      city: 'Paris',
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

/// Serves the seeded trip; [gate], when set, stalls every subsequent getTrip
/// until completed — freezing the screen on its optimistic state so the test
/// can assert the frame(s) rendered before the silent reload lands.
class _GatedTripsApiService extends TripsApiService {
  List<ItineraryItem> items;
  final List<List<String>> reorderCalls = [];
  Completer<void>? gate;
  _GatedTripsApiService(Trip trip)
      : items = trip.items!,
        super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    final g = gate;
    if (g != null) await g.future;
    // A fresh list per fetch, like a real JSON parse.
    return _tripWith(List.of(items));
  }

  @override
  Future<void> reorderItineraryItems(
      String tripId, List<String> itemIds) async {
    reorderCalls.add(itemIds);
    final byId = {for (final it in items) it.id: it};
    items = [for (final id in itemIds) byId[id]!];
  }
}

double _rowTop(WidgetTester tester, String name) => tester
    .getTopLeft(
        find.ancestor(of: find.text(name), matching: find.byType(ListTile)))
    .dy;

void main() {
  testWidgets(
      'inline drag renders the new order optimistically, before the silent '
      'reload resolves (epoch contract)', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = _GatedTripsApiService(_tripWith([
      _item(0, 'Louvre'),
      _item(1, 'Orsay'),
      _item(2, 'Pantheon'),
    ]));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripsApiServiceProvider.overrideWithValue(fake)],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: const TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();
    expect(_rowTop(tester, 'Louvre'), lessThan(_rowTop(tester, 'Orsay')));

    // Stall the post-reorder silent reload: everything rendered from here
    // until the gate opens comes from the optimistic in-place mutation.
    fake.gate = Completer<void>();

    final rowHeight = _rowTop(tester, 'Orsay') - _rowTop(tester, 'Louvre');
    final row = find.ancestor(
        of: find.text('Louvre'), matching: find.byType(ListTile));
    final handle =
        find.descendant(of: row, matching: find.byIcon(Icons.drag_indicator));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(Offset(0, (rowHeight + 20) / 5));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    // ONE frame after the drop: the setState(items.setAll + epoch bump) has
    // built exactly once and the reload is still gated. A stale derivation
    // (missing epoch bump) would rebuild the old order here.
    await tester.pump();
    // Let the drop animation finish — still fully optimistic (gate closed).
    await tester.pump(const Duration(milliseconds: 400));
    expect(fake.reorderCalls, [
      ['i-Orsay', 'i-Louvre', 'i-Pantheon']
    ]);
    expect(_rowTop(tester, 'Orsay'), lessThan(_rowTop(tester, 'Louvre')),
        reason: 'optimistic frame must render the dragged order');
    expect(_rowTop(tester, 'Louvre'), lessThan(_rowTop(tester, 'Pantheon')));

    // Release the reload; the server order (same permutation) settles in and
    // nothing snaps back.
    fake.gate!.complete();
    fake.gate = null;
    await tester.pumpAndSettle();
    expect(_rowTop(tester, 'Orsay'), lessThan(_rowTop(tester, 'Louvre')));
    expect(_rowTop(tester, 'Louvre'), lessThan(_rowTop(tester, 'Pantheon')));
  });
}
