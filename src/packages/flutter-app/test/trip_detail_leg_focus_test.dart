import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

// The two-way leg focus contract (specs/map-city-focus):
//   * expanding a city header focuses its leg on the map; focus follows the
//     LAST expanded section;
//   * collapsing the focused section returns the map to All; collapsing any
//     other section leaves the map alone;
//   * a chip tap focuses + expands, and on the wide layout rests the city
//     header just below the pinned chrome — phones never scroll;
//   * a focus change clears the map pin selection;
//   * bookings lenses (no city headers) get map-only chips, lens kept;
//   * revisited cities focus per RUN key; single-leg trips have no focus.

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
      day: day,
      city: city,
    );

/// Paris (2 items) → Rome (8 items — enough scroll extent for the desktop
/// rest-below-chrome assertion) → Berlin (1 item), all geocoded.
Trip _threeCityTrip() => Trip(
      id: 't1',
      title: 'Grand tour',
      status: 'planned',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-05',
      items: [
        _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
        _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        for (var k = 0; k < 8; k++)
          _item(2 + k, 'Roman Forum $k', 'Rome', 41.89 + k * 0.001, 12.49, 3),
        _item(10, 'Brandenburg Gate', 'Berlin', 52.5163, 13.3777, 4),
      ],
    );

Future<void> _pump(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapChip(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(MapLegChips),
    matching: find.text(label),
  ));
  // Settles the post-frame camera re-fit and (desktop) the 350ms page
  // scroll to the focused city header.
  await tester.pumpAndSettle();
}

TripMap _map(WidgetTester tester) =>
    tester.widget<TripMap>(find.byType(TripMap));

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets(
      'header taps drive focus: expand focuses, last expanded wins, '
      'collapsing the focused leg restores All, others are inert',
      (tester) async {
    // Tall surface: with the 364px map band pinned, expanded sections push
    // later headers below an 800px fold and header taps would miss.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    expect(_map(tester).fitSignature, isNull);

    // Expand Paris → its leg focuses; the map filters to Paris.
    await expandCity(tester, 'Paris');
    expect(_map(tester).fitSignature, 'Paris');
    expect(_map(tester).items.map((i) => i.name), ['Louvre', 'Orsay']);

    // Expanding Rome steals the focus (focus = last expanded).
    await expandCity(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');
    expect(_map(tester).items, hasLength(8));

    // Collapsing NON-focused Paris leaves the map alone.
    await expandCity(tester, 'Paris');
    expect(_map(tester).fitSignature, 'Rome');

    // Collapsing the focused Rome returns the map to All.
    await expandCity(tester, 'Rome');
    expect(_map(tester).fitSignature, isNull);
    expect(_map(tester).items, hasLength(11));
  });

  testWidgets(
      'desktop chip tap expands the section and rests its header just '
      'below the pinned chrome', (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(tester, _threeCityTrip());

    // Rome starts collapsed: its items aren't built.
    expect(find.text('Roman Forum 0'), findsNothing);

    await _tapChip(tester, 'Rome');

    expect(_map(tester).fitSignature, 'Rome');
    // The section expanded…
    expect(find.text('Roman Forum 0'), findsOneWidget);
    // …and its header rests right below the pinned chrome: the 364px map
    // band (12 + 340 + 12) + the 56px itinerary tab row = 420, measured
    // from the viewport top (the app bar's bottom — the scroll math lives
    // in viewport coordinates). The one correction pass tolerates ±2.
    final viewportTop = tester.getBottomLeft(find.byType(AppBar)).dy;
    final headerTop = tester
        .getTopLeft(find
            .ancestor(
                of: cityHeaderLabel('Rome'), matching: find.byType(Material))
            .first)
        .dy;
    expect((headerTop - (viewportTop + 420)).abs(), lessThanOrEqualTo(2),
        reason: 'Rome header should rest below map band + tab row');
  });

  testWidgets('phone chip tap focuses the map without scrolling the list',
      (tester) async {
    _useSurface(tester, const Size(375, 800));
    await _pump(tester, _threeCityTrip());

    final scrollable = find
        .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable))
        .first;
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);

    await _tapChip(tester, 'Rome');

    expect(_map(tester).fitSignature, 'Rome');
    // The section expanded, but the page did not move — the chips ride the
    // scroll-away preview card, and scrolling would hide the map itself.
    expect(find.text('Roman Forum 0'), findsOneWidget);
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
  });

  testWidgets('a focus change clears the map pin selection', (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    await expandCity(tester, 'Rome');
    // Tapping an item row selects its pin on the map.
    await tester.tap(find.text('Roman Forum 1'));
    await tester.pumpAndSettle();
    expect(_map(tester).selectedPosition, 3);

    // Focusing another leg clears the selection: a lingering one would
    // suppress content refits and keep a ghost highlight.
    await _tapChip(tester, 'Paris');
    expect(_map(tester).selectedPosition, isNull);
    expect(_map(tester).fitSignature, 'Paris');
  });

  testWidgets('bookings lens: a chip tap filters the map and keeps the lens',
      (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(tester, _threeCityTrip());

    // Enter the Bookings view (header tab; the trip has no todos, so the
    // label carries no count): the city groups leave the tree.
    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();
    expect(cityHeaderLabel('Paris'), findsNothing);

    // The chip still drives the map — and does NOT exit the lens.
    await _tapChip(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');
    expect(_map(tester).items, hasLength(8));
    expect(cityHeaderLabel('Paris'), findsNothing,
        reason: 'a map chip must not exit the bookings lens');
  });

  testWidgets('revisited city: each header run focuses its own leg',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Paris twice',
        status: 'planned',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        startDate: '2026-09-01',
        endDate: '2026-09-03',
        items: [
          _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
          _item(1, 'Colosseum', 'Rome', 41.8902, 12.4922, 2),
          _item(2, 'Marmottan', 'Paris', 48.8592, 2.2670, 3),
        ],
      ),
    );

    // The second Paris header focuses the SECOND run only.
    await expandCity(tester, 'Paris', index: 1);
    expect(_map(tester).fitSignature, 'Paris#2');
    expect(_map(tester).items.map((i) => i.name), ['Marmottan']);

    // And the first run stays its own focus target.
    await expandCity(tester, 'Paris', index: 0);
    expect(_map(tester).fitSignature, 'Paris');
    expect(_map(tester).items.map((i) => i.name), ['Louvre']);
  });

  testWidgets('single-leg trip: no chip strip, header taps never focus',
      (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Just Paris',
        status: 'planned',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        startDate: '2026-09-01',
        endDate: '2026-09-03',
        items: [
          _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
          _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        ],
      ),
    );

    // The strip renders nothing below two legs.
    expect(
      find.descendant(
          of: find.byType(MapLegChips), matching: find.byType(ChoiceChip)),
      findsNothing,
    );

    // The sole group seeds open; toggling it never writes focus — with one
    // leg, "All" and "the leg" are the same map, and a fit bump would snap
    // a user-panned camera for no visible change.
    await expandCity(tester, 'Paris'); // collapse (seeded open)
    expect(_map(tester).fitSignature, isNull);
    await expandCity(tester, 'Paris'); // expand again
    expect(_map(tester).fitSignature, isNull);
  });
}
