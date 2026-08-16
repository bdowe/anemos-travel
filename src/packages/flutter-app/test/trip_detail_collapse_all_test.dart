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
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

// Fold all / unfold all — the bulk destination-accordion control.
//
// The contract, in one place:
//   * ONE control with two directions, its state DERIVED every build from
//     the live groups — never stored, so an edit that adds or drops a
//     destination can't leave it lying;
//   * folding touches the CITY groups only, unfolding clears cities AND
//     days — deliberately not an identity round-trip, so that re-opening
//     one city by its own chevron restores the day state you left, while
//     "Expand all" is literally true;
//   * it is PURE LIST work: no map focus write, no camera move (the
//     decoupling #358 paid for), and no lens exit;
//   * it is NOT gated on canEdit or offline — a long itinerary you can only
//     read is exactly where folding helps most;
//   * wide carries it in the itinerary header row, narrow in the app-bar
//     overflow (the phone row's FittedBox budget is already spent).

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Zero coords everywhere: the screen then skips the map widget, so
/// `mapShown` is false and `_pinnedChrome` is just the 56px tab row. That
/// keeps the resting-slot arithmetic one constant instead of two.
ItineraryItem _item(int pos, String name, String city, int day) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

/// [cities] consecutive city runs, [days] days each, [perDay] items per day.
/// Item names carry city AND day so the two accordion levels stay separately
/// observable.
Trip _trip({
  int cities = 3,
  int days = 2,
  int perDay = 2,
  String? access,
}) {
  final items = <ItineraryItem>[];
  var pos = 0;
  var day = 1;
  for (var c = 1; c <= cities; c++) {
    for (var d = 1; d <= days; d++) {
      for (var k = 0; k < perDay; k++) {
        items.add(_item(pos++, 'C$c D$d stop $k', 'City$c', day));
      }
      day++;
    }
  }
  return Trip(
    id: 't1',
    title: 'Grand tour',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    // Past dates: no Today chip, so the header row is the resting shape.
    startDate: '2026-06-01',
    endDate: '2026-06-${(cities * days).toString().padLeft(2, '0')}',
    access: access,
    ownerName: access == null ? null : 'Brian',
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
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(
            of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
        .first)
    .position;

/// The city header's own Material — the same box `_cityHeaderKeys` target,
/// so geometry measured here matches the screen's scroll math.
Finder _headerMaterialOf(String city) => find
    .ancestor(of: cityHeaderLabel(city), matching: find.byType(Material))
    .first;

double _headerTop(WidgetTester tester, String city) =>
    tester.getTopLeft(_headerMaterialOf(city)).dy;

/// Scroll offset that rests [city]'s header in the pinned slot.
double _reveal(WidgetTester tester, String city) {
  final target = tester.renderObject(_headerMaterialOf(city));
  return RenderAbstractViewport.of(target).getOffsetToReveal(target, 0).offset;
}

/// Viewport top in global coordinates — the app bar's bottom.
double _viewportTop(WidgetTester tester) =>
    tester.getBottomLeft(find.byType(AppBar)).dy;

Future<void> _tapFold(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}

/// Opens the app-bar `⋮` and taps [label].
Future<void> _tapOverflow(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one tap folds every destination, and the control flips',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip());

    // Landing: everything open, the control offers the fold direction.
    expect(find.text('C1 D1 stop 0'), findsOneWidget);
    expect(find.text('C3 D2 stop 0'), findsOneWidget);
    expect(find.byTooltip('Collapse all'), findsOneWidget);
    expect(find.byIcon(Icons.unfold_less), findsOneWidget);

    await _tapFold(tester, 'Collapse all');

    // Every city's body is gone — not just the first — and every header
    // survives as a row.
    expect(find.textContaining('stop'), findsNothing);
    for (final city in const ['City1', 'City2', 'City3']) {
      expect(cityHeaderLabel(city), findsOneWidget);
    }
    // The control now offers the other direction, glyph and label together.
    expect(find.byTooltip('Expand all'), findsOneWidget);
    expect(find.byTooltip('Collapse all'), findsNothing);
    expect(find.byIcon(Icons.unfold_more), findsOneWidget);

    await _tapFold(tester, 'Expand all');
    expect(find.text('C1 D1 stop 0'), findsOneWidget);
    expect(find.text('C3 D2 stop 0'), findsOneWidget);
    expect(find.byTooltip('Collapse all'), findsOneWidget);
  });

  testWidgets('expand all re-opens days a header tap folded, not just cities',
      (tester) async {
    // The asymmetry, asserted. Unfold clears BOTH sets — an "Expand all"
    // that leaves a day shut is a liar, and nobody goes looking for a day
    // they folded three cities ago.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip());

    // Fold City1's day 1 by its own header.
    await tester.tap(find.text('Mon, Jun 1'));
    await tester.pumpAndSettle();
    expect(find.text('C1 D1 stop 0'), findsNothing);
    expect(find.text('C1 D2 stop 0'), findsOneWidget);

    await _tapFold(tester, 'Collapse all');
    await _tapFold(tester, 'Expand all');

    expect(find.text('C1 D1 stop 0'), findsOneWidget,
        reason: 'expand all must clear the day set too');
  });

  testWidgets('collapse all leaves day state alone', (tester) async {
    // The other half of the asymmetry: a folded city's days are invisible
    // either way, so folding preserves them and re-opening ONE city by its
    // own chevron restores exactly what the traveler left.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip());

    await tester.tap(find.text('Mon, Jun 1')); // City1 day 1
    await tester.pumpAndSettle();
    expect(find.text('C1 D1 stop 0'), findsNothing);

    await _tapFold(tester, 'Collapse all');
    await toggleCity(tester, 'City1'); // re-open just this city

    expect(find.text('C1 D1 stop 0'), findsNothing,
        reason: 'collapse all must not touch the day set');
    expect(find.text('C1 D2 stop 0'), findsOneWidget,
        reason: 'the rest of the city is back');
  });

  testWidgets('folding never touches the map', (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    // Real coordinates so the map renders and can record a fit.
    final items = <ItineraryItem>[
      for (var c = 1; c <= 3; c++)
        for (var k = 0; k < 2; k++)
          ItineraryItem(
            id: 'i$c$k',
            position: (c - 1) * 2 + k,
            name: 'C$c D1 stop $k',
            latitude: 40.0 + c,
            longitude: 10.0 + c,
            category: 'attraction',
            day: c,
            city: 'City$c',
          ),
    ];
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Grand tour',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          startDate: '2026-06-01',
          endDate: '2026-06-03',
          items: items,
        ));

    await _tapFold(tester, 'Collapse all');
    await _tapFold(tester, 'Expand all');

    // Expansion is list-only: a fold must not focus a leg or refit the
    // camera (specs/map-scroll-decouple).
    expect(tester.widget<TripMap>(find.byType(TripMap)).fitSignature, isNull);
  });

  testWidgets('folding keeps you on the destination you were reading',
      (tester) async {
    // Without the anchor re-rest, folding shrinks maxScrollExtent by
    // thousands of px and the position clamps — the traveler is dumped at
    // the end of a list they were reading the middle of.
    // 24 destinations so the FOLDED list is still taller than the viewport.
    // With fewer, the whole folded outline fits on screen, maxScrollExtent
    // is 0, and City6 cannot physically reach the resting slot — the
    // documented graceful degradation (_scrollToCityHeader clamps and the
    // correction pass no-ops), but it would make this test assert nothing.
    _useSurface(tester, const Size(1200, 900));
    await _pump(tester, _trip(cities: 24, days: 1, perDay: 2));

    final position = _position(tester);
    final slot = _viewportTop(tester) + 56; // no map: tab row only
    final mid = _reveal(tester, 'City6') + 200;
    expect(mid, lessThan(position.maxScrollExtent),
        reason: 'premise: mid-group-6 must be reachable');
    position.jumpTo(mid);
    await tester.pumpAndSettle();

    await _tapFold(tester, 'Collapse all');

    expect(_reveal(tester, 'City6'), lessThan(position.maxScrollExtent),
        reason: 'premise: the folded list must still be able to rest City6');
    expect((_headerTop(tester, 'City6') - slot).abs(), lessThanOrEqualTo(2),
        reason: 'the anchor group stays under the chrome after folding');

    // And back the other way: unfolding inserts five cities' bodies above
    // City6, so without the re-rest it would drop far below the fold.
    await _tapFold(tester, 'Expand all');
    expect((_headerTop(tester, 'City6') - slot).abs(), lessThanOrEqualTo(2),
        reason: 'the anchor group stays under the chrome after unfolding');
  });

  testWidgets('at the top of the list, folding leaves the scroll alone',
      (tester) async {
    _useSurface(tester, const Size(1200, 900));
    await _pump(tester, _trip(cities: 4));

    expect(_position(tester).pixels, 0);
    await _tapFold(tester, 'Collapse all');
    expect(_position(tester).pixels, 0,
        reason: 'no anchor above the rest line means no scroll at all');
  });

  testWidgets('a partly folded itinerary still offers Collapse all',
      (tester) async {
    // `every`, not `any`: one open destination means there is still
    // something to fold, and one tap must finish the job.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip());

    await collapseCity(tester, 'City1');
    expect(find.byTooltip('Collapse all'), findsOneWidget);
    expect(find.byTooltip('Expand all'), findsNothing);

    await _tapFold(tester, 'Collapse all');
    expect(find.textContaining('stop'), findsNothing);
    expect(find.byTooltip('Expand all'), findsOneWidget);
  });

  testWidgets('a place-less trip has no fold control', (tester) async {
    _useSurface(tester, const Size(1200, 900));
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Someday',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: const [],
        ));

    // Both glyphs, deliberately. Dropping the groups.isNotEmpty gate from
    // _foldControlShown renders the control here in its UNFOLD face — an
    // empty list satisfies `every`, so "everything is collapsed" comes out
    // true — which an unfold_less-only assertion would sail straight past
    // (mutation-checked: it does).
    expect(find.byIcon(Icons.unfold_less), findsNothing);
    expect(find.byIcon(Icons.unfold_more), findsNothing);
  });

  testWidgets('the Bookings and Budget views have no fold control',
      (tester) async {
    // Both swap the city groups out for flat lists — there is no accordion
    // there to fold.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip());

    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.unfold_less), findsNothing);

    await tester.tap(find.text('Budget'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.unfold_less), findsNothing);

    await tester.tap(find.text('Itinerary'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse all'), findsOneWidget);
  });

  testWidgets('a viewer folds too', (tester) async {
    // Pure view work: never gated on canEdit. A long shared itinerary you
    // can only read is exactly where this helps most.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _trip(access: 'viewer'));

    expect(find.text('Add place'), findsNothing, reason: 'premise: read-only');
    await _tapFold(tester, 'Collapse all');
    expect(find.textContaining('stop'), findsNothing);
  });

  testWidgets('narrow keeps the row clean and folds from the overflow menu',
      (tester) async {
    _useSurface(tester, const Size(390, 1600));
    await _pump(tester, _trip());

    // The phone header row is untouched — its FittedBox budget is spent.
    expect(find.byIcon(Icons.unfold_less), findsNothing);
    expect(find.byTooltip('Collapse all'), findsNothing);

    await _tapOverflow(tester, 'Collapse all');
    expect(find.textContaining('stop'), findsNothing);

    // ONE entry that flips, not two — a menu must not offer a dead action.
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Expand all'), findsOneWidget);
    expect(find.text('Collapse all'), findsNothing);
    await tester.tap(find.text('Expand all'));
    await tester.pumpAndSettle();
    expect(find.text('C1 D1 stop 0'), findsOneWidget);
  });
}
