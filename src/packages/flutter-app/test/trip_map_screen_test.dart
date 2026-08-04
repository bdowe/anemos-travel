import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/screens/trip_map_screen.dart';
import 'package:travel_route_planner/widgets/map_day_chips.dart';

import 'support/l10n_test_app.dart';

ItineraryItem _item(int pos, String name, double lat, double lng) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
    );

final _items = [
  _item(0, 'Louvre', 48.8606, 2.3376),
  _item(1, 'Café de Flore', 48.8540, 2.3326),
];

/// [viewPadding] simulates device chrome (e.g. the 34px iOS home-indicator
/// band) — the test binding's own MediaQuery always reports zero.
Widget _app({
  EdgeInsets viewPadding = EdgeInsets.zero,
  void Function(int? day)? onAddPlace,
  String title = 'Paris getaway',
}) {
  return MaterialApp(
    localizationsDelegates: testLocalizationsDelegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(padding: viewPadding, viewPadding: viewPadding),
      child: child!,
    ),
    home: TripMapScreen(
      title: title,
      itemsForDay: (_) => _items,
      staysForDay: (_) => const <Accommodation>[],
      segmentLabels: const {},
      dayCount: 3,
      onDaySelected: (_) {},
      onAddPlace: onAddPlace,
    ),
  );
}

void main() {
  testWidgets('bottom map controls clear a simulated home indicator', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 690));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(viewPadding: const EdgeInsets.only(bottom: 34)),
    );
    await tester.pumpAndSettle();

    // The body honors the bottom inset (SafeArea), so the reset button —
    // the lowest control in the zoom column — can't sit under the 34px
    // home-indicator band.
    final reset = find.byIcon(Icons.zoom_in_map);
    expect(reset, findsOneWidget);
    expect(tester.getBottomLeft(reset).dy, lessThanOrEqualTo(690 - 34));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'app bar carries a persistent add-place action wired to the current day',
    (tester) async {
      var called = false;
      int? receivedDay = -1;
      await tester.pumpWidget(
        _app(
          onAddPlace: (d) {
            called = true;
            receivedDay = d;
          },
        ),
      );
      await tester.pumpAndSettle();

      final action = find.byIcon(Icons.add_location_alt_outlined);
      expect(action, findsOneWidget);

      await tester.tap(action);
      expect(called, isTrue);
      expect(receivedDay, isNull); // opened on All

      // Selecting a day must carry through to the action.
      await tester.tap(
        find.descendant(
          of: find.byType(MapDayChips),
          matching: find.text('Day 2'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(action);
      expect(receivedDay, 2);
    },
  );

  testWidgets('read-only map (no onAddPlace) hides the add action', (
    tester,
  ) async {
    await tester.pumpWidget(_app(onAddPlace: null));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.add_location_alt_outlined), findsNothing);
  });

  testWidgets('long titles ellipsize instead of overflowing at 360px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 690));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const title = 'Barcelona, Madrid, Sevilla, Granada & 5 more';
    await tester.pumpWidget(_app(title: title));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text(title));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}
