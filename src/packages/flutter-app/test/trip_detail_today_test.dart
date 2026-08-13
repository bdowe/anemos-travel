import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

import 'support/l10n_test_app.dart';

/// Today mode (specs/today-mode PR 3): one-shot auto-scroll to today's day
/// header, the pinned "Today" jump chip, and the header highlight.
///
/// Dates are computed relative to DateTime.now() so "today" is always live.
/// Items carry zero coordinates so the map sliver is skipped — the scroll
/// math must land correctly with the map-hidden pinned-chrome height.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  int calls = 0;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    calls++;
    return trip;
  }
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

ItineraryItem _item(int pos, String name, int day,
        {double lat = 0, double lng = 0}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name street, Paris',
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: 'Paris',
    );

/// A three-day Paris trip: day 1 is long enough that today's (day 2) header
/// starts well below the fold, day 3 gives the scroll room to land day 2 at
/// the top.
Trip _liveTrip(
        {required String startDate,
        required String endDate,
        List<Accommodation>? accommodations}) =>
    Trip(
      id: 't1',
      title: 'Live Trip',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: startDate,
      endDate: endDate,
      accommodations: accommodations,
      items: [
        for (var k = 0; k < 6; k++) _item(k, 'Past stop $k', 1),
        for (var k = 0; k < 6; k++) _item(6 + k, 'Today stop $k', 2),
        for (var k = 0; k < 4; k++) _item(12 + k, 'Next stop $k', 3),
      ],
    );

Future<void> _pumpScreen(WidgetTester tester, TripsApiService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tripsApiServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// The "Today" StatusPill inside today's day header (the jump chip is an
/// ActionChip, so the two never collide).
Finder _todayPill() => find.widgetWithText(StatusPill, 'Today');

Finder _todayChip() => find.widgetWithText(ActionChip, 'Today');

void main() {
  final now = DateTime.now();
  // Today is day 2 of a 3-day trip that started yesterday.
  final start = _iso(now.subtract(const Duration(days: 1)));
  final end = _iso(now.add(const Duration(days: 1)));

  testWidgets(
      'live trip auto-scrolls once to today: header rests just below the '
      'pinned chrome, tinted, with a Today pill and jump chip',
      (WidgetTester tester) async {
    await _pumpScreen(
        tester, _FakeTripsApiService(_liveTrip(startDate: start, endDate: end)));

    // The one-shot scroll actually moved the list.
    expect(_position(tester).pixels, greaterThan(0));

    // Today's header carries the pill and the highlight tint (opaque: the
    // primary tint alpha-blended onto the scaffold background).
    expect(_todayPill(), findsOneWidget);
    final theme = Theme.of(tester.element(find.text('Itinerary')));
    final expectedTint = Color.alphaBlend(
        theme.colorScheme.primary.withValues(alpha: 0.06),
        theme.scaffoldBackgroundColor);
    final headerMaterial = tester.widget<Material>(find
        .ancestor(of: _todayPill(), matching: find.byType(Material))
        .first);
    expect(headerMaterial.color, expectedTint);

    // The header sits just below the pinned chrome: with zero-coord items
    // the map sliver is skipped, so the chrome is the itinerary title header
    // (100) plus the pinned city header above the day header.
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    final pillDy = tester.getTopLeft(_todayPill()).dy;
    expect(pillDy, greaterThan(viewportTop + 100));
    expect(pillDy, lessThan(viewportTop + 100 + 120));
    // Today's items start right under it.
    expect(find.text('Today stop 0'), findsOneWidget);

    // The jump chip renders in the pinned title row.
    expect(_todayChip(), findsOneWidget);
  });

  testWidgets('a silent refresh never re-triggers the auto-scroll (one-shot)',
      (WidgetTester tester) async {
    final service =
        _FakeTripsApiService(_liveTrip(startDate: start, endDate: end));
    await _pumpScreen(tester, service);
    expect(_position(tester).pixels, greaterThan(0));

    // Scroll back to the top, then drive a silent refresh through the fake
    // service via pull-to-refresh.
    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(service.calls, greaterThan(1)); // the refresh really refetched
    expect(_position(tester).pixels, 0); // ...and did not scroll
  });

  testWidgets('the Today chip expands a collapsed today section and scrolls',
      (WidgetTester tester) async {
    await _pumpScreen(
        tester, _FakeTripsApiService(_liveTrip(startDate: start, endDate: end)));

    // Collapse today's day by tapping its header (the pill sits inside the
    // header's InkWell), then park the list at the top.
    await tester.tap(_todayPill());
    await tester.pumpAndSettle();
    expect(find.text('Today stop 0'), findsNothing);
    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();

    await tester.tap(_todayChip());
    await tester.pumpAndSettle();

    // Expanded and scrolled: today's items are back and the header rests
    // below the pinned chrome again.
    expect(_position(tester).pixels, greaterThan(0));
    expect(find.text('Today stop 0'), findsOneWidget);
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    final pillDy = tester.getTopLeft(_todayPill()).dy;
    expect(pillDy, greaterThan(viewportTop + 100));
    expect(pillDy, lessThan(viewportTop + 100 + 120));
  });

  testWidgets('the Today chip from deep in the list scrolls monotonically',
      (WidgetTester tester) async {
    await _pumpScreen(
        tester, _FakeTripsApiService(_liveTrip(startDate: start, endDate: end)));

    // Park at the very bottom; today's (day 2) header sits well above it.
    // This is the map-hidden chrome configuration (56px tab row only) —
    // the phone-reachable scroll path.
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final parked = position.pixels;

    // Tap WITHOUT settling and sample the scroll frame by frame: double-
    // subtracting the pinned chrome animated 56px past the target and let
    // the correction pass snap back down — a direction reversal.
    await tester.tap(_todayChip());
    final samples = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      samples.add(position.pixels);
    }
    await tester.pumpAndSettle();
    samples.add(position.pixels);

    expect(samples.last, lessThan(parked),
        reason: "premise: today's rest offset must sit above the parked "
            'bottom position — otherwise this scenario went vacuous');
    var maxRise = 0.0;
    for (var i = 1; i < samples.length; i++) {
      final rise = samples[i] - samples[i - 1];
      if (rise > maxRise) maxRise = rise;
    }
    expect(maxRise, lessThanOrEqualTo(2),
        reason: 'a net-upward scroll must never move back down '
            '(up-then-down jank); from $parked: $samples');

    // And it still lands in the resting window the first test pins down.
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    final pillDy = tester.getTopLeft(_todayPill()).dy;
    expect(pillDy, greaterThan(viewportTop + 100));
    expect(pillDy, lessThan(viewportTop + 100 + 120));
  });

  testWidgets('a trip that ended yesterday gets no Today behavior',
      (WidgetTester tester) async {
    final trip = _liveTrip(
      startDate: _iso(now.subtract(const Duration(days: 3))),
      endDate: _iso(now.subtract(const Duration(days: 1))),
    );
    await _pumpScreen(tester, _FakeTripsApiService(trip));

    expect(_position(tester).pixels, 0);
    expect(_todayChip(), findsNothing);
    expect(_todayPill(), findsNothing);
  });

  testWidgets('an undated trip gets no Today behavior',
      (WidgetTester tester) async {
    final undated = Trip(
      id: 't1',
      title: 'Undated Trip',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        for (var k = 0; k < 6; k++) _item(k, 'Stop $k', 1),
        for (var k = 0; k < 6; k++) _item(6 + k, 'Later stop $k', 2),
      ],
    );
    await _pumpScreen(tester, _FakeTripsApiService(undated));

    expect(_position(tester).pixels, 0);
    expect(_todayChip(), findsNothing);
    expect(_todayPill(), findsNothing);
    expect(find.text('Day 1'), findsOneWidget); // plain headers, no dates
  });

  testWidgets("a live trip preselects today's leg on the map chips",
      (WidgetTester tester) async {
    // Real coordinates so the map sliver mounts — the auto-scroll then also
    // exercises the map-shown pinned-chrome height. Two cities so the leg
    // strip exists: today (day 2) belongs to the Rome leg.
    final trip = Trip(
      id: 't1',
      title: 'Live Mapped Trip',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: start,
      endDate: end,
      items: [
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Louvre',
          latitude: 48.8606,
          longitude: 2.3376,
          category: 'attraction',
          day: 1,
          city: 'Paris',
        ),
        ItineraryItem(
          id: 'i1',
          position: 1,
          name: 'Colosseum',
          latitude: 41.8902,
          longitude: 12.4922,
          category: 'attraction',
          day: 2,
          city: 'Rome',
        ),
      ],
    );
    await _pumpScreen(tester, _FakeTripsApiService(trip));

    expect(
        tester.widget<MapLegChips>(find.byType(MapLegChips)).selected, 'Rome');
    expect(_todayChip(), findsOneWidget);
  });

  group('Tonight caption (specs/happening-now PR 2)', () {
    // Coordinate-free stays: TripMap.stayHasCoords stays false, so the map
    // sliver never mounts and the scroll geometry the tests above pin down
    // is unchanged.
    Accommodation stay(String id, String name,
            {required int checkInOffset, required int checkOutOffset}) =>
        Accommodation(
          id: id,
          name: name,
          checkIn: _iso(now.add(Duration(days: checkInOffset))),
          checkOut: _iso(now.add(Duration(days: checkOutOffset))),
        );

    Finder tonight() => find.textContaining('Tonight: ');

    testWidgets('a stay covering tonight renders exactly one caption in '
        "today's section", (WidgetTester tester) async {
      final trip = _liveTrip(startDate: start, endDate: end, accommodations: [
        stay('a1', 'Hôtel du Nord', checkInOffset: -1, checkOutOffset: 2),
      ]);
      await _pumpScreen(tester, _FakeTripsApiService(trip));

      // The auto-scroll parked today's header at the top; the caption is the
      // section's first content row, directly under it.
      expect(tonight(), findsOneWidget);
      expect(find.text('Tonight: Hôtel du Nord'), findsOneWidget);
      final pillDy = tester.getTopLeft(_todayPill()).dy;
      final captionDy = tester.getTopLeft(tonight()).dy;
      expect(captionDy, greaterThan(pillDy));
      expect(captionDy,
          lessThan(tester.getTopLeft(find.text('Today stop 0')).dy));
    });

    testWidgets('a stay checking out today never claims tonight '
        '(checkout-exclusive)', (WidgetTester tester) async {
      final trip = _liveTrip(startDate: start, endDate: end, accommodations: [
        stay('a1', 'Hôtel du Nord', checkInOffset: -1, checkOutOffset: 0),
      ]);
      await _pumpScreen(tester, _FakeTripsApiService(trip));

      expect(tonight(), findsNothing);
    });

    testWidgets('a trip that ended yesterday shows no caption',
        (WidgetTester tester) async {
      final trip = _liveTrip(
        startDate: _iso(now.subtract(const Duration(days: 3))),
        endDate: _iso(now.subtract(const Duration(days: 1))),
        accommodations: [
          stay('a1', 'Hôtel du Nord', checkInOffset: -1, checkOutOffset: 2),
        ],
      );
      await _pumpScreen(tester, _FakeTripsApiService(trip));

      expect(tonight(), findsNothing);
    });

    testWidgets('an undated trip shows no caption',
        (WidgetTester tester) async {
      final undated = Trip(
        id: 't1',
        title: 'Undated Trip',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        accommodations: [
          stay('a1', 'Hôtel du Nord', checkInOffset: -1, checkOutOffset: 2),
        ],
        items: [
          for (var k = 0; k < 3; k++) _item(k, 'Stop $k', 1),
          for (var k = 0; k < 3; k++) _item(3 + k, 'Later stop $k', 2),
        ],
      );
      await _pumpScreen(tester, _FakeTripsApiService(undated));

      expect(tonight(), findsNothing);
    });

    testWidgets('two stays covering tonight are comma-joined',
        (WidgetTester tester) async {
      final trip = _liveTrip(startDate: start, endDate: end, accommodations: [
        stay('a1', 'Hôtel A', checkInOffset: -1, checkOutOffset: 2),
        stay('a2', 'Hôtel B', checkInOffset: 0, checkOutOffset: 1),
      ]);
      await _pumpScreen(tester, _FakeTripsApiService(trip));

      expect(find.text('Tonight: Hôtel A, Hôtel B'), findsOneWidget);
    });

    testWidgets('an empty-name stay is skipped in the joined names',
        (WidgetTester tester) async {
      final trip = _liveTrip(startDate: start, endDate: end, accommodations: [
        stay('a1', '  ', checkInOffset: -1, checkOutOffset: 2),
        stay('a2', 'Hôtel B', checkInOffset: -1, checkOutOffset: 2),
      ]);
      await _pumpScreen(tester, _FakeTripsApiService(trip));

      expect(find.text('Tonight: Hôtel B'), findsOneWidget);
    });

    testWidgets('only empty-name stays render no caption at all',
        (WidgetTester tester) async {
      final trip = _liveTrip(startDate: start, endDate: end, accommodations: [
        stay('a1', '  ', checkInOffset: -1, checkOutOffset: 2),
      ]);
      await _pumpScreen(tester, _FakeTripsApiService(trip));

      expect(tonight(), findsNothing);
    });

    testWidgets("collapsing today's day hides the caption with the section",
        (WidgetTester tester) async {
      final trip = _liveTrip(startDate: start, endDate: end, accommodations: [
        stay('a1', 'Hôtel du Nord', checkInOffset: -1, checkOutOffset: 2),
      ]);
      await _pumpScreen(tester, _FakeTripsApiService(trip));
      expect(tonight(), findsOneWidget);

      await tester.tap(_todayPill());
      await tester.pumpAndSettle();

      expect(find.text('Today stop 0'), findsNothing); // really collapsed
      expect(tonight(), findsNothing);
    });

    testWidgets('two city groups containing today render exactly one caption',
        (WidgetTester tester) async {
      ItineraryItem cityItem(int pos, String name, int day, String city) =>
          ItineraryItem(
            id: 'i$pos',
            position: pos,
            name: name,
            address: '$name street, $city',
            latitude: 0,
            longitude: 0,
            category: 'attraction',
            day: day,
            city: city,
          );
      // Day 2 (today) spans the Paris→Lyon handover, so BOTH city groups
      // render a "Day 2" section; the caption may appear only in the first.
      final trip = Trip(
        id: 't1',
        title: 'Two Cities',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        startDate: start,
        endDate: end,
        accommodations: [
          stay('a1', 'Hôtel du Nord', checkInOffset: -1, checkOutOffset: 2),
        ],
        items: [
          cityItem(0, 'Louvre', 1, 'Paris'),
          cityItem(1, 'Marais walk', 2, 'Paris'),
          cityItem(2, 'Confluence', 2, 'Lyon'),
          cityItem(3, 'Fourvière', 3, 'Lyon'),
        ],
      );
      await _pumpScreen(tester, _FakeTripsApiService(trip));

      expect(find.text('Paris'), findsWidgets);
      expect(find.text('Lyon'), findsWidgets);
      expect(tonight(), findsOneWidget);
    });
  });
}
