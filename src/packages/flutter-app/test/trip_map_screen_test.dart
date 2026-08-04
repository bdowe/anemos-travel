import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
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
  String? homeAirport,
  LatLng? firstCityPoint,
  LatLng? lastCityPoint,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
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
        homeAirport: homeAirport,
        firstCityPoint: firstCityPoint,
        lastCityPoint: lastCityPoint,
      ),
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

  group('home-airport legs', () {
    // Newark, far enough from the Paris fixtures that the fit visibly widens.
    const homePoint = (lat: 40.6895, lng: -74.1745);
    final firstCity = LatLng(_items.first.latitude, _items.first.longitude);
    final lastCity = LatLng(_items.last.latitude, _items.last.longitude);

    Widget appWithHome() => _app(
          homeAirport: 'EWR',
          firstCityPoint: firstCity,
          lastCityPoint: lastCity,
          overrides: [
            homeAirportPointProvider('EWR')
                .overrideWith((ref) async => homePoint),
          ],
        );

    Future<void> tapDay(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(MapDayChips),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'home pin shows on All and the endpoint days, hides mid-trip',
      (tester) async {
        await tester.pumpWidget(appWithHome());
        await tester.pumpAndSettle();

        // "All": both legs → home pin present.
        expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);

        // Mid-trip day: neither leg belongs to it → no orphan pin.
        await tapDay(tester, 'Day 2');
        expect(find.byIcon(Icons.flight_takeoff), findsNothing);

        // Day 1 carries the outbound leg, the last day the return leg.
        await tapDay(tester, 'Day 1');
        expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);
        await tapDay(tester, 'Day 3');
        expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('unresolved home airport renders the map as before', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          homeAirport: 'EWR',
          firstCityPoint: firstCity,
          lastCityPoint: lastCity,
          overrides: [
            // Lookup failed / no coordinates → provider contract yields null.
            homeAirportPointProvider('EWR').overrideWith((ref) async => null),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.flight_takeoff), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no saved home airport never touches the provider', (
      tester,
    ) async {
      // No override registered: a provider read would throw in this scope if
      // the network path were exercised.
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.flight_takeoff), findsNothing);
      expect(tester.takeException(), isNull);
    });
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
