import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/screens/trip_map_screen.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/chip_finders.dart';
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

/// Three legs so the home-overlay matrix has a first, a middle, and a last.
const _legChips = [
  (key: 'Paris', label: 'Paris', qualifier: null),
  (key: 'Rome', label: 'Rome', qualifier: null),
  (key: 'Berlin', label: 'Berlin', qualifier: null),
];

/// [viewPadding] simulates device chrome (e.g. the 34px iOS home-indicator
/// band) — the test binding's own MediaQuery always reports zero.
Widget _app({
  EdgeInsets viewPadding = EdgeInsets.zero,
  void Function(String? legKey)? onAddPlace,
  void Function(String? legKey)? onLegSelected,
  String title = 'Paris getaway',
  String? homeAirport,
  LatLng? firstCityPoint,
  LatLng? lastCityPoint,
  List<TripMapDestination>? destinations,
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
        itemsForLeg: (_) => _items,
        staysForLeg: (_) => const <Accommodation>[],
        segmentLabels: const {},
        legChips: _legChips,
        onLegSelected: onLegSelected ?? (_) {},
        onAddPlace: onAddPlace,
        homeAirport: homeAirport,
        firstCityPoint: firstCityPoint,
        lastCityPoint: lastCityPoint,
        destinations: destinations,
      ),
    ),
  );
}

Future<void> _tapChip(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(MapLegChips),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
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
    'app bar carries a persistent add-place action wired to the current leg',
    (tester) async {
      var called = false;
      String? receivedLeg = 'sentinel';
      await tester.pumpWidget(
        _app(
          onAddPlace: (k) {
            called = true;
            receivedLeg = k;
          },
        ),
      );
      await tester.pumpAndSettle();

      final action = find.byIcon(Icons.add_location_alt_outlined);
      expect(action, findsOneWidget);

      await tester.tap(action);
      expect(called, isTrue);
      expect(receivedLeg, isNull); // opened on All

      // Selecting a leg must carry through to the action.
      await _tapChip(tester, 'Rome');
      await tester.tap(action);
      expect(receivedLeg, 'Rome');
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

    testWidgets(
      'home pin shows on the overview and the endpoint legs, hides mid-trip',
      (tester) async {
        await tester.pumpWidget(appWithHome());
        await tester.pumpAndSettle();

        // Unfocused overview: both legs → home pin present.
        expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);

        // Mid-trip leg: neither home leg belongs to it → no orphan pin.
        await _tapChip(tester, 'Rome');
        expect(find.byIcon(Icons.flight_takeoff), findsNothing);

        // The first leg carries the outbound leg, the last leg the return.
        await _tapChip(tester, 'Paris');
        expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);
        await _tapChip(tester, 'Berlin');
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

  group('destination pins (trip overview)', () {
    // Leg keys match the chip keys, as trip detail passes them — the pins on
    // this screen are navigable (see the chip-equivalent test below).
    const dests = [
      TripMapDestination(
        label: 'Paris',
        point: LatLng(48.8566, 2.3522),
        legKey: 'Paris',
      ),
      TripMapDestination(
        label: 'Rome',
        point: LatLng(41.9028, 12.4964),
        legKey: 'Rome',
      ),
    ];

    Finder inMap(String text) =>
        find.descendant(of: find.byType(FlutterMap), matching: find.text(text));

    testWidgets(
        'All shows destination pins; leg chips flip to item pins '
        'and back', (tester) async {
      await tester.pumpWidget(_app(destinations: dests));
      await tester.pumpAndSettle();

      // All: the overview — numbered destinations, no clusterer.
      expect(find.byType(MarkerClusterLayerWidget), findsNothing);
      expect(inMap('1'), findsOneWidget);
      expect(inMap('2'), findsOneWidget);

      // A leg focus restores per-item pins (the fixture's two items).
      await _tapChip(tester, 'Paris');
      expect(find.byType(MarkerClusterLayerWidget), findsOneWidget);

      await tapMapReset(tester);
      expect(find.byType(MarkerClusterLayerWidget), findsNothing);
      expect(inMap('1'), findsOneWidget);
      expect(inMap('2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a destination-pin tap is the chip-equivalent: leg selected in '
        'place and reported back', (tester) async {
      String? reported = 'sentinel';
      await tester.pumpWidget(
        _app(destinations: dests, onLegSelected: (k) => reported = k),
      );
      await tester.pumpAndSettle();

      // Drive the wired callback directly (the robust screen-level pattern;
      // pin tap geometry is covered in trip_map_test).
      tester.widget<TripMap>(find.byType(TripMap)).onDestinationTap!('Rome');
      await tester.pumpAndSettle();

      // In place: the camera-refit signal flips to the leg, the overview
      // pins hand off to per-item pins, and the chip row follows — no pop.
      final map = tester.widget<TripMap>(find.byType(TripMap));
      expect(map.fitSignature, 'Rome');
      expect(map.destinations, isNull);
      expect(find.byType(MarkerClusterLayerWidget), findsOneWidget);
      expect(
        tester.widget<MapLegChips>(find.byType(MapLegChips)).selected,
        'Rome',
      );

      // Trip detail hears about it (it pre-scrolls the list behind the
      // modal so closing lands on the region).
      expect(reported, 'Rome');
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
