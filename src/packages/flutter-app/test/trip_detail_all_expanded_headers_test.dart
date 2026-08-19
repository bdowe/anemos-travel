import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/trip_detail/map_band.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

// The N-expanded-groups pinning + scroll-math contract (list expansion is
// decoupled from map focus; there is no single-open accordion):
//   * every city group defaults EXPANDED and toggles independently —
//     _collapsedGroups is inverted state (empty = all expanded), so all N
//     bodies contribute scroll extent from the first frame;
//   * while scrolling, exactly ONE city header obstructs at a time: each
//     group's containing MultiSliver pushes its own header off at the
//     group's end, so consecutive headers hand off edge-to-edge and the
//     pinned slot ([_pinnedSlot]: the map band plus the tab row) never
//     accumulates obstruction as more groups pin and unpin;
//   * header taps are pure list toggles — the map-side assertions live in
//     trip_detail_leg_focus_test.dart; here they only pin down that N
//     groups collapse and re-expand independently;
//   * destination (region) pins on the All-overview map navigate the LIST:
//     un-collapse the group + rest its header in the pinned slot, with NO
//     focus write and no camera move. The far-upward-scroll probe rides
//     that path because it is the one that crosses unbuilt item batches,
//     where the scroll target comes from SliverList extent ESTIMATES.

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

/// Paris (days 1–2) → Rome (days 3–4) → Berlin ([berlinDays] days from day
/// 5), [perDay] geocoded items per day. With every group expanded by
/// default all three bodies contribute extent immediately. The pinning
/// tests give Berlin extra days so the trailing extent is deep enough for
/// its header to reach the pinned slot on the tall surface — and, in the
/// estimation probe, so Paris's item batches sit far beyond the cache
/// extent when parked at the bottom.
Trip _trip({required int perDay, required int berlinDays}) {
  final items = <ItineraryItem>[];
  var pos = 0;
  void city(String name, double lat, double lng, List<int> days) {
    var n = 0;
    for (final day in days) {
      for (var k = 0; k < perDay; k++) {
        items.add(
            _item(pos++, '$name stop ${n++}', name, lat + n * 0.001, lng, day));
      }
    }
  }

  city('Paris', 48.86, 2.33, [1, 2]);
  city('Rome', 41.89, 12.49, [3, 4]);
  city('Berlin', 52.51, 13.37, [for (var d = 0; d < berlinDays; d++) 5 + d]);
  return Trip(
    id: 't1',
    title: 'Grand tour',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    startDate: '2026-09-01',
    endDate: '2026-09-${(4 + berlinDays).toString().padLeft(2, '0')}',
    items: items,
  );
}

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

TripMap _map(WidgetTester tester) =>
    tester.widget<TripMap>(find.byType(TripMap));

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The city header's own Material (opaque so items can't show through while
/// pinned) — the same box the screen's _cityHeaderKeys target, so geometry
/// measured here matches the scroll math's.
Finder _headerMaterialOf(String city) => find
    .ancestor(of: cityHeaderLabel(city), matching: find.byType(Material))
    .first;

double _headerTop(WidgetTester tester, String city) =>
    tester.getTopLeft(_headerMaterialOf(city)).dy;

/// The scroll offset that rests [city]'s header in the pinned slot —
/// getOffsetToReveal at alignment 0, which already subtracts the pinned
/// map band + tab row (maxScrollObstructionExtentBefore). City headers are
/// SliverPinnedHeader children, always built, so this works at any offset;
/// accuracy depends on how much of the intervening item batches is built.
double _reveal(WidgetTester tester, String city) {
  final target = tester.renderObject(_headerMaterialOf(city));
  return RenderAbstractViewport.of(target).getOffsetToReveal(target, 0).offset;
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable))
        .first)
    .position;

/// Viewport top in global coordinates — the app bar's bottom; the pinned
/// chrome math lives in viewport coordinates.
double _viewportTop(WidgetTester tester) =>
    tester.getBottomLeft(find.byType(AppBar)).dy;

/// The screen's own pinned tab-row extent (`_listHeaderHeight`, private to
/// the screen). Restated, not derived — but paired with [mapBandHeaderHeight]
/// below so the half of this sum that DOES move with a redesign is read from
/// its source. It was a bare `420` until the wave-2 header lane retuned the
/// band, which failed these two tests by exactly the 60px it removed.
const double _tabRowHeight = 56;

/// Where a pinned city header comes to rest: below the map band and the tab
/// row, in viewport coordinates.
double _pinnedSlot(WidgetTester tester) =>
    _viewportTop(tester) + mapBandHeaderHeight + _tabRowHeight;

void main() {
  testWidgets('exactly one city header pins; the next city pushes it off',
      (tester) async {
    // Tall surface: the pinned map band pushes deep-group geometry
    // below an 800px fold. Berlin's six days keep enough trailing extent
    // (item tiles are ~58px) that a mid-group-3 offset stays reachable on
    // the ~1724px content viewport.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip(perDay: 6, berlinDays: 6));

    final position = _position(tester);
    final slot = _pinnedSlot(tester);
    final headerH = tester.getRect(_headerMaterialOf('Paris')).height;

    // Deep inside Rome's body: Rome's header has pinned.
    final romeMid = _reveal(tester, 'Rome') + 250;
    expect(romeMid, lessThan(position.maxScrollExtent),
        reason: 'premise: mid-group-2 must be reachable');
    position.jumpTo(romeMid);
    await tester.pumpAndSettle();

    final slotDy = _headerTop(tester, 'Rome');
    expect((slotDy - slot).abs(), lessThanOrEqualTo(2),
        reason: 'Rome header should pin below map band + tab row');
    // Paris — the previous group's header — has been pushed fully off the
    // slot (its own MultiSliver's end carried it up), not stacked above it.
    expect(_headerTop(tester, 'Paris'), lessThanOrEqualTo(slotDy - headerH + 2),
        reason: 'the pushed-off Paris header must sit clear above the slot');
    // Berlin's header is still in flow below the pinned one.
    expect(_headerTop(tester, 'Berlin'), greaterThan(slotDy + headerH),
        reason: 'Berlin scrolls in flow until its own body reaches the slot');

    // Same jump into group 3: the slot dy is CONSTANT. If pushed-off
    // headers accumulated as obstructions, each later group would rest
    // lower than the one before.
    final berlinMid = _reveal(tester, 'Berlin') + 250;
    expect(berlinMid, lessThan(position.maxScrollExtent),
        reason: 'premise: mid-group-3 must be reachable');
    position.jumpTo(berlinMid);
    await tester.pumpAndSettle();

    expect((_headerTop(tester, 'Berlin') - slotDy).abs(), lessThanOrEqualTo(2),
        reason: 'slot constancy: no obstruction accumulation across groups');
    expect(_headerTop(tester, 'Rome'), lessThanOrEqualTo(slotDy - headerH + 2),
        reason: 'Rome is pushed off the slot in turn');
  });

  testWidgets('push handoff is edge-to-edge', (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip(perDay: 6, berlinDays: 6));
    final position = _position(tester);

    // Approach the boundary first so the item batches around it build and
    // the reveal offset is exact, not a SliverList estimate.
    position.jumpTo(_reveal(tester, 'Rome') - 400);
    await tester.pumpAndSettle();
    final r2 = _reveal(tester, 'Rome');
    final headerH = tester.getRect(_headerMaterialOf('Paris')).height;
    // Paris is pinned here, so its top measures the slot empirically.
    final slotDy = _headerTop(tester, 'Paris');

    // Fine sweep across the group-1 → group-2 boundary. The push window in
    // offset terms is [r2 - headerH, r2]: Rome's header enters the band at
    // Paris's pinned bottom and finishes at the slot itself.
    var handoffSamples = 0;
    for (var off = r2 - headerH - 24; off <= r2 + 24; off += 4) {
      position.jumpTo(off);
      await tester.pump();
      final paris = tester.getRect(_headerMaterialOf('Paris'));
      final rome = tester.getRect(_headerMaterialOf('Rome'));
      // Both headers occupy the band: Rome has entered it and Paris has
      // not fully left it.
      if (rome.top < slotDy + headerH - 0.5 && paris.bottom > slotDy + 0.5) {
        handoffSamples++;
        expect((paris.bottom - rome.top).abs(), lessThanOrEqualTo(1),
            reason: 'at offset $off the handoff must be edge-to-edge: '
                'no gap and no overlap between the outgoing and incoming '
                'headers (Paris bottom ${paris.bottom}, Rome top ${rome.top})');
      }
    }
    expect(handoffSamples, greaterThan(3),
        reason: 'premise: the sweep must actually cross the push window');
  });

  testWidgets('multi-group independent collapse', (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip(perDay: 4, berlinDays: 2));

    // Groups default EXPANDED: bodies render with no tap.
    expect(find.text('Paris stop 0'), findsOneWidget);
    expect(find.text('Rome stop 0'), findsOneWidget);

    // Collapse groups 1 and 3. Paris first: dropping its body pulls
    // Berlin's header above the fold, so the second tap lands (offscreen
    // taps no-op with only a warning).
    await collapseCity(tester, 'Paris');
    expect(_headerTop(tester, 'Berlin'), lessThan(2100),
        reason: 'premise: Berlin header must be on screen for its tap');
    await collapseCity(tester, 'Berlin');

    // Each group renders per its OWN state — no accordion coupling.
    expect(find.text('Paris stop 0'), findsNothing);
    expect(find.text('Rome stop 0'), findsOneWidget);
    expect(find.text('Berlin stop 0'), findsNothing);

    // Re-expanding Berlin leaves the other two alone.
    await toggleCity(tester, 'Berlin');
    expect(find.text('Paris stop 0'), findsNothing,
        reason: 'expanding one group must not re-expand another');
    expect(find.text('Rome stop 0'), findsOneWidget);
    expect(find.text('Berlin stop 0'), findsOneWidget);
    // And none of the header taps touched the map: pure list toggles.
    expect(_map(tester).fitSignature, isNull);
  });

  // Doubles as the regression test for the quiescent-tap frame stall: a
  // destination-pin tap on an already-expanded group (the default state)
  // changes no state, and addPostFrameCallback does not request a frame —
  // _revealCityHeader's ensureVisualUpdate is what guarantees the scroll
  // runs at all (deterministic under the test binding, whose pump skips
  // frame production while hasScheduledFrame is false).
  testWidgets('far upward scroll to a region lands without reversal',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip(perDay: 6, berlinDays: 6));
    final position = _position(tester);

    // Park at the very bottom. Twice: the first jump can shift
    // maxScrollExtent as SliverList estimates correct against built
    // children; the second lands on the settled value.
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final start = position.pixels;

    // Premise for the estimation regime: Paris's item tiles sit beyond the
    // cache extent, so the scroll target for its header is computed over
    // ESTIMATED child offsets — the overshoot-prone path.
    expect(find.text('Paris stop 0'), findsNothing,
        reason: 'premise: city-1 items must be unbuilt for the probe to '
            'exercise offset estimation');

    // Region-pin tap for city 1 on the inline All-overview map, invoked
    // directly (the robust pattern at the screen level). No settle: the
    // whole point is to watch the motion.
    final map = _map(tester);
    expect(map.onDestinationTap, isNotNull,
        reason: 'the desktop inline card wires destination-pin navigation');
    map.onDestinationTap!('Paris');

    // Sample the scroll frame by frame across the 350ms animation plus the
    // one-jump correction pass.
    final samples = <double>[];
    for (var i = 0; i < 16; i++) {
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
            '(overshoot-then-snap-back reversal); from $start: $samples');

    // And it lands exactly: city 1's header rests in the pinned slot.
    final slot = _pinnedSlot(tester);
    expect((_headerTop(tester, 'Paris') - slot).abs(), lessThanOrEqualTo(2),
        reason: 'Paris header should rest below map band + tab row');
    // The navigation was list-only: no focus write, camera untouched, the
    // destination pins still render.
    expect(_map(tester).fitSignature, isNull,
        reason: 'a destination-pin tap must not write map focus');
    expect(_map(tester).destinations, isNotNull,
        reason: 'the All-overview pins must survive their own tap');
  });
}
