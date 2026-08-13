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

// The accordion city-focus contract (specs/map-city-focus, accordion rev):
//   * the open group IS the selection: expanding a city header focuses its
//     leg on the map and closes the previously open group — at most one
//     group is ever open;
//   * collapsing the open group (or tapping the All chip) deselects both
//     ways: the map returns to All and everything is collapsed;
//   * a chip tap selects — focuses + opens the leg's group — and on the
//     wide layout rests the city header just below the pinned chrome;
//     phones never scroll;
//   * a map pin tap reveals its run in the list WITHOUT moving the camera
//     (reveal-only), and a focus change clears the map pin selection;
//   * bookings lenses (no city headers) get map-only chips, lens kept;
//     places lenses resolve legs onto merged groups (groupKeyForLeg);
//   * revisited cities focus per RUN key; single-leg trips have no focus.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// getTrip flips from [v1] to [v2] once addItineraryItem is called, so the
/// screen's post-add `_load()` sees the new item (the Add-place flow).
class _AddingTripsApiService extends TripsApiService {
  final Trip v1;
  final Trip v2;
  bool added = false;
  _AddingTripsApiService(this.v1, this.v2)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => added ? v2 : v1;

  @override
  Future<Trip> addItineraryItem(String tripId, Map<String, dynamic> body) async {
    added = true;
    return v2;
  }
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
      'header taps drive the accordion: expanding selects and closes the '
      'previous group, collapsing the open group restores All',
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
    expect(find.text('Louvre'), findsOneWidget);

    // Expanding Rome selects it — and closes Paris: at most one group open.
    await expandCity(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');
    expect(_map(tester).items, hasLength(8));
    expect(find.text('Louvre'), findsNothing,
        reason: 'selecting Rome must close the previously open Paris');

    // Collapsing the open Rome deselects: map to All, list all collapsed.
    await expandCity(tester, 'Rome');
    expect(_map(tester).fitSignature, isNull);
    expect(_map(tester).items, hasLength(11));
    expect(find.text('Roman Forum 0'), findsNothing);
  });

  testWidgets(
      'desktop chip tap expands the section and rests its header just '
      'below the pinned chrome', (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(tester, _threeCityTrip());

    // Rome starts collapsed: its items aren't built. Open Paris first so
    // the chip tap also proves the accordion closes it.
    expect(find.text('Roman Forum 0'), findsNothing);
    await expandCity(tester, 'Paris');
    expect(find.text('Louvre'), findsOneWidget);

    await _tapChip(tester, 'Rome');

    expect(_map(tester).fitSignature, 'Rome');
    // The section expanded — exclusively…
    expect(find.text('Roman Forum 0'), findsOneWidget);
    expect(find.text('Louvre'), findsNothing,
        reason: 'a chip tap closes the previously open group');
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

  testWidgets(
      'chip tap scrolls straight to the target: no up-then-down reversal',
      (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(tester, _threeCityTrip());

    // Open Rome (8 items) for scroll extent, then park at the very bottom.
    // The regression only shows on a net-upward scroll: from the top the
    // buggy motion (animate clamped at ~0, one down-snap) was still
    // monotone and the resting assert above passed all along.
    await _tapChip(tester, 'Rome');
    final scrollable = find
        .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final start = position.pixels;

    // Tap Paris WITHOUT settling, then sample the scroll frame by frame:
    // double-subtracting the pinned chrome animated ~420px past the target
    // and let the correction pass snap back down — a direction reversal
    // mid-gesture.
    await tester.tap(find.descendant(
        of: find.byType(MapLegChips), matching: find.text('Paris')));
    final samples = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      samples.add(position.pixels);
    }
    await tester.pumpAndSettle();
    samples.add(position.pixels);

    expect(samples.last, lessThan(start),
        reason: 'premise: the Paris rest offset must sit above the parked '
            'bottom position — otherwise this scenario went vacuous');
    var maxRise = 0.0;
    for (var i = 1; i < samples.length; i++) {
      final rise = samples[i] - samples[i - 1];
      if (rise > maxRise) maxRise = rise;
    }
    expect(maxRise, lessThanOrEqualTo(2),
        reason: 'a net-upward scroll must never move back down '
            '(up-then-down jank); from $start: $samples');

    // And it still lands exactly: Paris rests below the pinned chrome.
    final viewportTop = tester.getBottomLeft(find.byType(AppBar)).dy;
    final headerTop = tester
        .getTopLeft(find
            .ancestor(
                of: cityHeaderLabel('Paris'), matching: find.byType(Material))
            .first)
        .dy;
    expect((headerTop - (viewportTop + 420)).abs(), lessThanOrEqualTo(2),
        reason: 'Paris header should rest below map band + tab row');
  });

  testWidgets('the All chip deselects both ways: map to All, group closed',
      (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(tester, _threeCityTrip());

    await _tapChip(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');
    expect(find.text('Roman Forum 0'), findsOneWidget);

    // All = nothing selected: chips and headers are two views of ONE
    // selection, so the open group closes with the map reset.
    await _tapChip(tester, 'All');
    expect(_map(tester).fitSignature, isNull);
    expect(_map(tester).items, hasLength(11));
    expect(find.text('Roman Forum 0'), findsNothing,
        reason: 'the All chip closes the open group');
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

  testWidgets('a pin tap reveals its run without moving the camera',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    // From the All view, tap a Rome pin (invoked directly — marker hit
    // boxes cluster-shift): its run opens so the highlighted row is
    // reachable, but the camera must NOT refit out from under the
    // zoom-to-pin move — fitSignature stays All.
    _map(tester).onPinTap!(2);
    await tester.pumpAndSettle();
    expect(_map(tester).selectedPosition, 2);
    expect(_map(tester).fitSignature, isNull);
    // A sibling row, not the tapped item's name — that one also renders in
    // the pin-tap snackbar.
    expect(find.text('Roman Forum 1'), findsOneWidget);

    // The reveal-only open group still collapses coherently: the map is
    // already on All, so closing it changes nothing on the map.
    await expandCity(tester, 'Rome');
    expect(_map(tester).fitSignature, isNull);
    expect(find.text('Roman Forum 1'), findsNothing);
  });

  testWidgets('a pin tap while a leg is focused keeps the camera and selection',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    // Focus Rome, then tap a Rome pin: keepCamera must be a no-op on the
    // focus (a focused map already renders only that leg's pins), so the
    // camera stays on Rome AND the selection is NOT cleared — the pin-tap
    // camera invariant.
    await _tapChip(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');

    _map(tester).onPinTap!(3);
    await tester.pumpAndSettle();
    expect(_map(tester).fitSignature, 'Rome', reason: 'camera must not refit');
    expect(_map(tester).selectedPosition, 3,
        reason: 'keepCamera must not clear the selection');
    // Rome stays the open group; Paris stays closed.
    expect(find.text('Roman Forum 1'), findsWidgets);
    expect(find.text('Louvre'), findsNothing);
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

  testWidgets(
      'places lens: a merged group opens for either of its legs '
      '(groupKeyForLeg)', (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Paris twice',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        startDate: '2026-09-01',
        endDate: '2026-09-03',
        items: [
          _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
          ItineraryItem(
            id: 'i1',
            position: 1,
            name: 'Osteria',
            latitude: 41.8902,
            longitude: 12.4922,
            category: 'restaurant',
            day: 2,
            city: 'Rome',
          ),
          _item(2, 'Marmottan', 'Paris', 48.8592, 2.2670, 3),
        ],
      ),
    );

    // The Attractions lens drops Rome's only item: the two Paris runs merge
    // into ONE group keyed 'Paris', while the chips stay trip-wide (All +
    // Paris + Rome + Paris).
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    await tester.tap(find.ancestor(
        of: find.text('Attractions'),
        matching: find.byWidgetPredicate((w) => w is CheckedPopupMenuItem)));
    await tester.pumpAndSettle();

    // Selecting the SECOND Paris run focuses its leg — and opens the one
    // merged group both runs resolve to.
    final parisChips = find.descendant(
        of: find.byType(MapLegChips), matching: find.text('Paris'));
    await tester.tap(parisChips.at(1));
    await tester.pumpAndSettle();
    expect(_map(tester).fitSignature, 'Paris#2');
    expect(_map(tester).items.map((i) => i.name), ['Marmottan']);
    expect(find.text('Louvre'), findsOneWidget,
        reason: 'the merged Paris group holds both runs\' attractions');
    expect(find.text('Marmottan'), findsWidgets);

    // Selecting the first run refocuses the map; the same merged group
    // simply stays open.
    await tester.tap(parisChips.at(0));
    await tester.pumpAndSettle();
    expect(_map(tester).fitSignature, 'Paris');
    expect(_map(tester).items.map((i) => i.name), ['Louvre']);
    expect(find.text('Louvre'), findsOneWidget);
  });

  testWidgets('adding a place focuses the added city, closing the previous',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    final v1 = _threeCityTrip();
    // v2 inserts a fresh Rome item (consecutive with the existing Rome run,
    // so it stays leg 'Rome'), Berlin shifted after it.
    final v2 = Trip(
      id: 't1',
      title: 'Grand tour',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-05',
      items: [
        _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
        _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        for (var k = 0; k < 8; k++)
          _item(2 + k, 'Roman Forum $k', 'Rome', 41.89 + k * 0.001, 12.49, 3),
        // Fresh item: a unique id (NOT position-derived, which would collide
        // with v1's Berlin id 'i10'); consecutive with Rome so it stays
        // leg 'Rome'.
        const ItineraryItem(
          id: 'fresh-trevi',
          position: 10,
          name: 'Trevi Fountain',
          latitude: 41.9009,
          longitude: 12.4833,
          category: 'attraction',
          day: 3,
          city: 'Rome',
        ),
        // Berlin keeps its v1 id ('i10') so it is NOT seen as fresh; only
        // the position shifts.
        const ItineraryItem(
          id: 'i10',
          position: 11,
          name: 'Brandenburg Gate',
          latitude: 52.5163,
          longitude: 13.3777,
          category: 'attraction',
          day: 4,
          city: 'Berlin',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_AddingTripsApiService(v1, v2)),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Open Paris so the add can be shown to CLOSE it (the item lands in Rome).
    await expandCity(tester, 'Paris');
    expect(_map(tester).fitSignature, 'Paris');
    expect(find.text('Louvre'), findsOneWidget);

    // Header "Add place" → manual entry → name → Add.
    await tester.tap(find.text('Add place'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Can't find it? Add manually"));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Place name').first, 'Trevi Fountain');
    await tester.tap(
        find.descendant(of: find.byType(AlertDialog), matching: find.text('Add')));
    await tester.pumpAndSettle();

    // The new item's leg (Rome) is now focused and its group open; Paris,
    // the previously open group, is closed.
    expect(_map(tester).fitSignature, 'Rome');
    expect(find.text('Trevi Fountain'), findsWidgets);
    expect(find.text('Louvre'), findsNothing,
        reason: 'the previously open Paris closes under the accordion');
  });

  testWidgets('single-leg trip: no chip strip, header taps never focus',
      (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Just Paris',
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
    // a user-panned camera for no visible change. The LIST still toggles
    // through the reveal-only hatch (this is the same writer path an
    // 'Other places'-only trip takes).
    expect(find.text('Louvre'), findsOneWidget); // seeded open
    await expandCity(tester, 'Paris'); // collapse (seeded open)
    expect(_map(tester).fitSignature, isNull);
    expect(find.text('Louvre'), findsNothing, reason: 'list collapsed');
    await expandCity(tester, 'Paris'); // expand again
    expect(_map(tester).fitSignature, isNull);
    expect(find.text('Louvre'), findsOneWidget, reason: 'list reopened');
  });
}
