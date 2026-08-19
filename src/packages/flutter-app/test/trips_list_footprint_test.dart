import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/city_pin.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/shared_with_me_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/section_header.dart';
import 'package:travel_route_planner/widgets/stat_tile_row.dart';
import 'package:travel_route_planner/widgets/travel_footprint_card.dart';

import 'support/l10n_test_app.dart';

/// The "Your travels" section on the trips list (specs/trips-page-insights):
/// the footprint map plus the travel stats that caption it, gated at 2+ OWNED
/// trips —
/// shared-with-me is someone else's travel and carries none of the fields.
/// The map sub-band is gated separately on having pins; with none the card
/// degrades to a bare stats strip rather than showing an empty globe.
///
/// The stats come in two labeled groups, traveled and planned, and **a group
/// with no trips does not render** — the rule that keeps a planner who has
/// taken no trips yet from meeting a row of zeros, and the reason this card
/// needs no second display mode. Groups are found by key, not by label, so the
/// invariant is asserted the same way in any locale.
///
/// The "Your travels" title is a page-level SectionHeader ABOVE the card, not
/// inside it — an unlabeled map over a stats panel is the "Up next" hero's
/// silhouette, so an in-card label let the whole thing read as another
/// upcoming trip. Header and card share one gate, so neither renders alone.
///
/// Dates are relative to DateTime.now() so the split stays deterministic. Tile
/// HTTP in widget tests 400s and is silently tolerated, so map assertions are
/// structural (FlutterMap presence), never imagery.
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;

  _FixedTripsApiService(this.trips) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => trips;
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Trip _trip(String id, String title,
        {String? start,
        String? end,
        List<String>? cities,
        List<CityPin>? pins,
        String? access}) =>
    Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      cities: cities,
      cityPins: pins,
      access: access,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpList(
  WidgetTester tester, {
  List<Trip> trips = const [],
  List<Trip> shared = const [],
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
        sharedWithMeProvider.overrideWith((ref) async => shared),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripsListScreen()),
    ),
  );
}

/// Scopes a finder to the band, so a tile value can't be satisfied by a
/// number printed on a trip card elsewhere on the page.
Finder _inBand(Finder matching) => find.descendant(
    of: find.byType(TravelFootprintCard), matching: matching);

/// Scopes a finder to ONE stat group — with two groups on screen, "2" and
/// "trips" both appear twice, so every stat assertion has to say which side.
Finder _inGroup(Key group, Finder matching) =>
    find.descendant(of: find.byKey(group), matching: matching);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('two owned trips raise the band, map and all',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip',
          start: _rel(10),
          end: _rel(13),
          cities: const ['Lisbon'],
          pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
      _trip('t2', 'Athens Trip',
          start: _rel(40),
          end: _rel(45),
          cities: const ['Athens'],
          pins: const [CityPin(city: 'Athens', lat: 37.9, lng: 23.7)]),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsOneWidget);
    expect(find.text('Your travels'), findsOneWidget);
    expect(_inBand(find.byType(FlutterMap)), findsOneWidget);
    expect(_inBand(find.byType(StatTileRow)), findsOneWidget);
    // The label sits ABOVE the card as a page-level section header, never
    // inside it: an in-card label under the map is what let this read as
    // another upcoming trip card.
    expect(_inBand(find.text('Your travels')), findsNothing);
    // ...and it renders as a peer of "Upcoming", not as card chrome.
    expect(
      find.ancestor(
          of: find.text('Your travels'), matching: find.byType(SectionHeader)),
      findsOneWidget,
    );
  });

  testWidgets('one owned trip gets no band — even beside a shared trip',
      (WidgetTester tester) async {
    // The gate counts OWNED trips: a lifetime aggregate of one trip only
    // restates the hero above it, and shared rows carry no insight fields.
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip',
          start: _rel(10),
          end: _rel(13),
          pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
    ], shared: [
      _trip('s1', 'Shared Trip',
          start: _rel(20), end: _rel(23), access: 'editor'),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsNothing);
    expect(find.text('Your travels'), findsNothing);
    expect(find.text('Shared Trip'), findsOneWidget);
  });

  testWidgets('a shared-only account gets no band',
      (WidgetTester tester) async {
    await _pumpList(tester, shared: [
      _trip('s1', 'Shared Trip',
          start: _rel(10), end: _rel(13), access: 'editor'),
      _trip('s2', 'Other Shared Trip',
          start: _rel(20), end: _rel(23), access: 'editor'),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsNothing);
    expect(find.text('Your travels'), findsNothing);
  });

  testWidgets('pin-less trips collapse the map but keep the header and tiles',
      (WidgetTester tester) async {
    // Old server, or trips whose items are all unlocated: coordinates are
    // never invented, so the card degrades to a bare stats strip. The section
    // header is a sibling above it, so the tiles stay labeled either way —
    // one of the reasons the label moved out of the card.
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip',
          start: _rel(10), end: _rel(13), cities: const ['Lisbon']),
      _trip('t2', 'Athens Trip',
          start: _rel(40), end: _rel(45), cities: const ['Athens']),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(TravelFootprintCard), findsOneWidget);
    expect(find.text('Your travels'), findsOneWidget);
    expect(_inBand(find.byType(StatTileRow)), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
  });

  testWidgets('a finished trip and an upcoming one report as separate groups',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      // 5 travel days, long over.
      _trip('past', 'Iberia Loop',
          start: _rel(-30), end: _rel(-26), cities: const ['Lisbon', 'Porto']),
      // 3 travel days over 2 cities, still ahead.
      _trip('next', 'Madrid Trip',
          start: _rel(10),
          end: _rel(12),
          cities: const ['Madrid', 'Toledo']),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Traveled'), findsOneWidget);
    expect(_inGroup(kTraveledStatsKey, find.text('1')), findsOneWidget);
    expect(_inGroup(kTraveledStatsKey, find.text('trip')), findsOneWidget);
    expect(_inGroup(kTraveledStatsKey, find.text('5')), findsOneWidget);
    expect(_inGroup(kTraveledStatsKey, find.text('2')), findsOneWidget);
    expect(_inGroup(kTraveledStatsKey, find.text('cities')), findsOneWidget);

    expect(find.text('Planned'), findsOneWidget);
    expect(_inGroup(kPlannedStatsKey, find.text('1')), findsOneWidget);
    expect(_inGroup(kPlannedStatsKey, find.text('3')), findsOneWidget);
    expect(_inGroup(kPlannedStatsKey, find.text('travel days')), findsOneWidget);
    expect(_inGroup(kPlannedStatsKey, find.text('2')), findsOneWidget);

    // The old single all-time strip would have said 2 trips / 8 days / 3
    // cities — no stat anywhere now claims travel that hasn't happened.
    expect(_inBand(find.text('8')), findsNothing);
  });

  testWidgets('an in-progress trip counts only the days lived through',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      // Started 2 days ago, 5 more to run: 3 days travelled so far.
      _trip('live', 'Athens Now',
          start: _rel(-2), end: _rel(5), cities: const ['Athens']),
      _trip('later', 'Madrid Trip',
          start: _rel(10), end: _rel(12), cities: const ['Madrid']),
    ]);
    await tester.pumpAndSettle();

    expect(_inGroup(kTraveledStatsKey, find.text('3')), findsOneWidget);
    expect(_inGroup(kTraveledStatsKey, find.text('8')), findsNothing);
  });

  testWidgets('a planner with nothing travelled yet gets no Traveled group',
      (WidgetTester tester) async {
    // The whole reason the groups are gated: three zeros would be a worse
    // welcome than the old (wrong) all-time totals.
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip',
          start: _rel(10), end: _rel(13), cities: const ['Lisbon']),
      _trip('t2', 'Athens Trip',
          start: _rel(40), end: _rel(45), cities: const ['Athens', 'Delphi']),
    ]);
    await tester.pumpAndSettle();

    expect(find.byKey(kTraveledStatsKey), findsNothing);
    expect(find.text('Traveled'), findsNothing);
    expect(find.byKey(kPlannedStatsKey), findsOneWidget);
    expect(_inGroup(kPlannedStatsKey, find.text('2')), findsOneWidget);
    expect(_inBand(find.text('0')), findsNothing);
  });

  testWidgets('an account with only finished trips gets no Planned group',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', 'Iberia Loop',
          start: _rel(-30), end: _rel(-26), cities: const ['Lisbon']),
      _trip('t2', 'Athens Trip',
          start: _rel(-90), end: _rel(-85), cities: const ['Athens', 'Delphi']),
    ]);
    await tester.pumpAndSettle();

    expect(find.byKey(kPlannedStatsKey), findsNothing);
    expect(find.text('Planned'), findsNothing);
    expect(_inGroup(kTraveledStatsKey, find.text('2')), findsOneWidget);
    expect(_inBand(find.text('0')), findsNothing);
  });

  testWidgets('zero-valued segments drop out; the trips stat always stays',
      (WidgetTester tester) async {
    // Undated, city-less legacy rows contribute no days and no cities — and
    // an undated draft is a plan, not travel taken.
    await _pumpList(tester, trips: [
      _trip('d1', 'Someday Trip'),
      _trip('d2', 'Another Someday'),
    ]);
    await tester.pumpAndSettle();

    expect(find.byKey(kTraveledStatsKey), findsNothing);
    expect(_inGroup(kPlannedStatsKey, find.text('2')), findsOneWidget);
    expect(_inGroup(kPlannedStatsKey, find.text('trips')), findsOneWidget);
    expect(find.text('travel days'), findsNothing);
    expect(find.text('cities'), findsNothing);
  });

  // The atlas door (the "See all" action in this section's header).
  //
  // It is gated on FINISHED trips — tripIsPast — and that predicate is the
  // whole point. The card's own gate counts owned trips; travelStats counts
  // trips that have STARTED. Either would open the door for an account whose
  // atlas has no traveled pins, no Traveled colophon group (it doesn't render
  // at zero) and an index with no rows at all.
  //
  // One pump per test: _pumpList installs a fresh tripsApiServiceProvider
  // override, which resets the tripsProvider that reads it.
  group('the atlas door', () {
    testWidgets('absent with one finished trip', (WidgetTester tester) async {
      await _pumpList(tester, trips: [
        _trip('past', 'Iberia Loop', start: _rel(-30), end: _rel(-26)),
        _trip('next', 'Madrid Trip', start: _rel(10), end: _rel(12)),
      ]);
      await tester.pumpAndSettle();

      expect(find.byKey(kTravelAtlasSeeAllKey), findsNothing);
      // The band itself is present — the two gates ask different questions.
      expect(find.byType(TravelFootprintCard), findsOneWidget);
      // And the header keeps the action that fills the history, which is how
      // this account earns the door.
      expect(find.byKey(kLogTripSectionActionKey), findsOneWidget);
    });

    testWidgets('present at two finished trips', (WidgetTester tester) async {
      await _pumpList(tester, trips: [
        _trip('past', 'Iberia Loop', start: _rel(-30), end: _rel(-26)),
        _trip('older', 'Athens Trip', start: _rel(-90), end: _rel(-85)),
      ]);
      await tester.pumpAndSettle();

      expect(find.byKey(kTravelAtlasSeeAllKey), findsOneWidget);
    });

    testWidgets('absent when the second started trip is still under way',
        (WidgetTester tester) async {
      // travelStats reports two traveled trips here. One of them is happening
      // right now, and a retrospective is not where it belongs — the same
      // category error the list already refuses for "Past trips".
      await _pumpList(tester, trips: [
        _trip('past', 'Iberia Loop', start: _rel(-30), end: _rel(-26)),
        _trip('live', 'Athens Now', start: _rel(-2), end: _rel(5)),
      ]);
      await tester.pumpAndSettle();

      expect(find.byKey(kTravelAtlasSeeAllKey), findsNothing);
      // ...and the band still counts it as traveled, unchanged: the gate moved,
      // the colophon did not.
      expect(find.byKey(kTraveledStatsKey), findsOneWidget);
    });

    testWidgets('both header actions live in the header, and neither escapes it',
        (WidgetTester tester) async {
      // Deliberately NO assertion about which line each action lands on, or
      // about one overflowing: those are text-width claims, and a widget test
      // lays out with Flutter's fixed-width test font rather than Inter. An
      // earlier version of this test pinned a three-line stack that the real
      // app never produces — verified in the browser, where 360dp English puts
      // the title and both actions on ONE line and 360dp Spanish drops the
      // pair together onto a second.
      //
      // The action group is a Wrap rather than a Row so that it CAN break
      // inside itself if it ever needs to — large accessibility text scales,
      // a longer translation. That is a defensive choice, not a fix for an
      // overflow at any shipped width.
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpList(tester, trips: [
        _trip('past', 'Porto', start: _rel(-30), end: _rel(-26)),
        _trip('older', 'Naxos', start: _rel(-90), end: _rel(-85)),
      ]);
      await tester.pumpAndSettle();

      // The test font is wider than Inter, so rigid chrome elsewhere on the
      // page (the "Past trips" collapsible's title + count pill) overflows
      // HERE and not in the app — checked in the browser at this width in both
      // languages, where that row ellipsizes its summary and fits. Consumed so
      // it cannot fail teardown; asserted to be the only one, so a header that
      // overflowed as well would turn this into "Multiple exceptions" and
      // fail.
      expect(tester.takeException().toString(),
          isNot(contains('Multiple exceptions')));

      // Both live INSIDE the section header, not one orphaned beside it...
      final header = find.ancestor(
          of: find.byKey(kTravelAtlasSeeAllKey),
          matching: find.byType(SectionHeader));
      expect(header, findsOneWidget);
      expect(
          find.descendant(
              of: header, matching: find.byKey(kLogTripSectionActionKey)),
          findsOneWidget);

      // ...grouped by a Wrap, which is the one property the comment above
      // exists for and the one a Row would pass everything else while
      // failing. It cannot be asserted as "there is a Wrap in the header":
      // SectionHeader supplies one of its own (title + action slot), so that
      // holds for a Row too. What distinguishes them is which Wrap is
      // NEAREST the button — the action group's, holding both actions and
      // not the title, or SectionHeader's, holding the title as well.
      final group = find
          .ancestor(
              of: find.byKey(kTravelAtlasSeeAllKey),
              matching: find.byType(Wrap))
          .first;
      expect(
          find.descendant(
              of: group, matching: find.byKey(kLogTripSectionActionKey)),
          findsOneWidget,
          reason: 'the two actions are wrapped together, as one group');
      expect(find.descendant(of: group, matching: find.text('Your travels')),
          findsNothing,
          reason: 'a Row action group would leave SectionHeader\'s own Wrap '
              'as the nearest one, and that holds the title too');
      // ...and neither runs past its edge, whichever line it lands on.
      final bounds = tester.getRect(header);
      for (final key in [kTravelAtlasSeeAllKey, kLogTripSectionActionKey]) {
        final button = tester.getRect(find.byKey(key));
        expect(button.right, lessThanOrEqualTo(bounds.right + 0.5));
        expect(button.left, greaterThanOrEqualTo(bounds.left - 0.5));
      }
      // PR #401's pin still holds: the title is a page-level header outside
      // the card, and the actions did not drag it inside.
      expect(
          find.descendant(
              of: find.byType(TravelFootprintCard),
              matching: find.text('Your travels')),
          findsNothing);
    });
  });

  testWidgets('the map marks visited cities apart from planned ones',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('past', 'Iberia Loop',
          start: _rel(-30),
          end: _rel(-26),
          cities: const ['Lisbon'],
          pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
      _trip('next', 'Madrid Trip',
          start: _rel(10),
          end: _rel(12),
          cities: const ['Madrid'],
          pins: const [CityPin(city: 'Madrid', lat: 40.4, lng: -3.7)]),
    ]);
    await tester.pumpAndSettle();

    // The dot styles are the fast read; the tooltip is the one that can't be
    // misread, so that is what the test pins.
    expect(_inBand(find.byTooltip('Lisbon · Traveled')), findsOneWidget);
    expect(_inBand(find.byTooltip('Madrid · Planned')), findsOneWidget);
  });
}
