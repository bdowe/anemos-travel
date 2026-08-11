import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

// The cluster package decides whether to re-run full cluster-tree
// construction with an identity check on its marker list, so TripMap caches
// the list keyed on (items identity, tappable). These tests pin that
// contract: selection changes and parent rebuilds must reuse the identical
// list; swapping the items list must produce a fresh one.

ItineraryItem _item(int pos, String name, double lat, double lng) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
    );

// Far apart (Paris / Rome) so the fitted camera renders two separate pins,
// never one cluster bubble.
final _itemsA = [
  _item(0, 'Louvre', 48.8606, 2.3376),
  _item(1, 'Colosseum', 41.8902, 12.4922),
];

Widget _app(List<ItineraryItem> items, {int? selectedPosition}) => MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
      home: Scaffold(
        body: TripMap(
          items: items,
          selectedPosition: selectedPosition,
          onPinTap: (_) {},
        ),
      ),
    );

void main() {
  testWidgets(
      'selection change and view-only rebuild keep the identical marker list',
      (tester) async {
    await tester.pumpWidget(_app(_itemsA));
    await tester.pump();

    final dynamic state = tester.state(find.byType(TripMap));
    final List<dynamic>? initial = state.debugClusterMarkerCache;
    expect(initial, isNotNull);
    expect(initial, hasLength(2));

    // Selecting a pin re-runs build with a new selectedPosition on the SAME
    // items list — the marker list must be the identical object (the cluster
    // layer then skips re-clustering) and the selected pin still grows via
    // its ValueListenableBuilder.
    await tester.pumpWidget(_app(_itemsA, selectedPosition: 1));
    await tester.pump();
    expect(identical(state.debugClusterMarkerCache, initial), isTrue);
    expect(
      find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 28 && w.height == 28),
      findsOneWidget,
    );

    // A view-only parent rebuild (same items, same selection) also reuses it.
    await tester.pumpWidget(_app(_itemsA, selectedPosition: 1));
    await tester.pump();
    expect(identical(state.debugClusterMarkerCache, initial), isTrue);
  });

  testWidgets('swapping the items list produces a fresh marker list',
      (tester) async {
    await tester.pumpWidget(_app(_itemsA));
    await tester.pump();
    final dynamic state = tester.state(find.byType(TripMap));
    final List<dynamic>? initial = state.debugClusterMarkerCache;
    expect(initial, isNotNull);

    // A new list instance (what a day filter or refresh delivers) must
    // rebuild markers — identity is the cache key, not deep equality.
    final itemsB = List.of(_itemsA)..add(_item(2, 'Pantheon', 41.8986, 12.4769));
    await tester.pumpWidget(_app(itemsB));
    await tester.pump();
    expect(identical(state.debugClusterMarkerCache, initial), isFalse);
    expect(state.debugClusterMarkerCache, hasLength(3));
  });
}
