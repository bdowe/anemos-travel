import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/city_pin.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/app_routes.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/shared_with_me_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/travel_atlas_screen.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/section_header.dart';

import 'support/l10n_test_app.dart';
import 'support/url_sync_fakes.dart';

/// The travel atlas — the "See all" destination of "Your travels".
///
/// The invariant the whole surface turns on is **membership**: the index holds
/// finished trips only (`tripIsPast`), never trips merely started. The band on
/// the trips list partitions on `tripHasStarted` because an aggregate should
/// count the days already lived through; a row that names ONE trip and claims
/// its length must not, or a 14-day trip on day 2 renders "2 days" and changes
/// every morning.
///
/// Tile HTTP in widget tests 400s and is silently tolerated, so map assertions
/// are structural (FlutterMap / camera / pin tooltips), never imagery.
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

/// A whole calendar year that is provably behind us whatever day the suite
/// runs. Year membership is what the chips key on, so fixtures that care about
/// it are anchored to a year rather than to a day offset: two trips 40 and 400
/// days ago land in one calendar year or two depending on the date the suite
/// runs, which would make the chip row appear and disappear by the season.
final int _lastYear = DateTime.now().year - 1;

Trip _trip(
  String id,
  String title, {
  String? start,
  String? end,
  List<String>? cities,
  List<CityPin>? pins,
}) =>
    Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      cities: cities,
      cityPins: pins,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

/// Two finished trips in ONE year, plus one still ahead — the shape the door
/// is gated on, and (being single-year) the shape that shows no chip row.
List<Trip> _history() => [
      _trip('past1', 'Iberia Loop',
          start: '$_lastYear-02-01',
          end: '$_lastYear-02-08', // 8 days
          cities: const ['Lisbon', 'Porto'],
          pins: const [CityPin(city: 'Lisbon', lat: 38.7, lng: -9.1)]),
      _trip('past2', 'Athens Trip',
          start: '$_lastYear-09-01',
          end: '$_lastYear-09-06', // 6 days
          cities: const ['Athens'],
          pins: const [CityPin(city: 'Athens', lat: 37.9, lng: 23.7)]),
      _trip('ahead', 'Madrid Trip',
          start: _rel(20),
          end: _rel(24),
          cities: const ['Madrid'],
          pins: const [CityPin(city: 'Madrid', lat: 40.4, lng: -3.7)]),
    ];

/// The shell's bottom navigation bar, which this screen is always pushed
/// under at phone widths. 80 is [NavigationBar]'s M3 height, and it is the
/// difference between the viewport and the actual fold — measuring without it
/// reads one index row too many.
const double kShellNavBarHeight = 80;

/// Mounts the atlas over a fixed trips payload, under a stand-in for the
/// shell's bottom navigation bar so vertical measurements are against the
/// fold a traveler actually sees.
///
/// **One pump per test.** Re-pumping installs a fresh
/// `tripsApiServiceProvider` override, which invalidates the `tripsProvider`
/// that depends on it and resets the list to empty — a second pump would
/// assert against an account with no trips rather than against a new fixture.
Future<void> _pumpAtlas(
  WidgetTester tester, {
  required List<Trip> trips,
  Size surface = const Size(390, 844),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
        sharedWithMeProvider.overrideWith((ref) async => const <Trip>[]),
      ],
      child: localizedTestApp(
        home: const Scaffold(
          body: TravelAtlasScreen(),
          bottomNavigationBar: SizedBox(height: kShellNavBarHeight),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [_history] plus an older year, so the year chip row renders.
List<Trip> spanningHistory() => [
      ..._history(),
      _trip('older', 'Rome Trip',
          start: '${_lastYear - 2}-09-01',
          end: '${_lastYear - 2}-09-05',
          cities: const ['Rome'],
          pins: const [CityPin(city: 'Rome', lat: 41.9, lng: 12.5)]),
    ];

/// The live camera of the mounted plate, read from inside its subtree.
MapCamera _camera(WidgetTester tester) =>
    MapCamera.of(tester.element(find.byType(TileLayer).first));

Finder _inIndex(Finder matching) =>
    find.descendant(of: find.byKey(kAtlasIndexKey), matching: matching);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('renders the plate, the colophon and the index', (tester) async {
    await _pumpAtlas(tester, trips: _history());

    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byKey(kAtlasTraveledStatsKey), findsOneWidget);
    expect(find.byKey(kAtlasPlannedStatsKey), findsOneWidget);
    expect(_inIndex(find.byType(SectionHeader)), findsOneWidget);
    expect(_inIndex(find.text('Iberia Loop')), findsOneWidget);
    expect(_inIndex(find.text('Athens Trip')), findsOneWidget);
  });

  testWidgets(
      'the index holds finished trips only; a planned one stays on the map',
      (tester) async {
    await _pumpAtlas(tester, trips: _history());

    // The map is *everywhere*; the index is *where you have been*.
    expect(_inIndex(find.text('Madrid Trip')), findsNothing);
    expect(find.byTooltip('Madrid · Planned'), findsOneWidget);
    expect(find.byTooltip('Lisbon · Traveled'), findsOneWidget);
  });

  testWidgets('a trip currently under way gets no index row', (tester) async {
    // The load-bearing distinction: travelStats would count this as traveled,
    // and its row would claim a length that grows every morning.
    await _pumpAtlas(tester, trips: [
      ..._history(),
      _trip('live', 'Naxos Now',
          start: _rel(-2), end: _rel(5), cities: const ['Naxos']),
    ]);

    expect(_inIndex(find.text('Naxos Now')), findsNothing);
    expect(_inIndex(find.text('Iberia Loop')), findsOneWidget);
  });

  testWidgets('rows print their length; a half-dated trip prints none',
      (tester) async {
    await _pumpAtlas(tester, trips: [
      ..._history(),
      // End date only, long past — tripIsPast accepts it, dayCount cannot
      // measure it, and "0 days" would be a lie about a trip that took some.
      _trip('half', 'Split & Hvar', end: _rel(-800), cities: const ['Split']),
    ]);

    expect(_inIndex(find.text('8 days')), findsOneWidget);
    expect(_inIndex(find.text('6 days')), findsOneWidget);
    expect(_inIndex(find.text('Split & Hvar')), findsOneWidget);
    expect(_inIndex(find.text('0 days')), findsNothing);
  });

  testWidgets('the zoom buttons move the camera', (tester) async {
    // Required because the plate opts out of scroll-wheel zoom: without them a
    // full-bleed desktop map could not be zoomed at all.
    await _pumpAtlas(tester, trips: _history());

    final before = _camera(tester).zoom;
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(_camera(tester).zoom, greaterThan(before));

    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pumpAndSettle();
    expect(_camera(tester).zoom, closeTo(before, 0.001));
  });

  // Two pumps, two tests: re-pumping a fresh `tripsApiServiceProvider`
  // override inside ONE test resets the tripsProvider it feeds, so the second
  // half would assert against an empty account rather than a narrow layout.
  testWidgets('at 900 the index reads beside the plate', (tester) async {
    await _pumpAtlas(tester, trips: _history(), surface: const Size(1200, 900));

    final plate = tester.getRect(find.byType(FlutterMap));
    final index = tester.getRect(find.byKey(kAtlasIndexKey));
    expect(index.left, greaterThanOrEqualTo(plate.right),
        reason: 'the index reads beside the plate, not under it');
    // Full-bleed: the atlas does not inherit the trips list's capped reading
    // column, because the surface is map-led.
    expect(plate.height, greaterThan(600),
        reason: 'the plate fills the height, it is not a letterboxed band');
    expect(plate.left, 0.0);
  });

  testWidgets('below 900 the index stacks under the plate', (tester) async {
    await _pumpAtlas(tester, trips: _history(), surface: const Size(390, 844));

    final plate = tester.getRect(find.byType(FlutterMap));
    final index = tester.getRect(find.byKey(kAtlasIndexKey));
    expect(index.top, greaterThanOrEqualTo(plate.bottom));
    expect(plate.width, 390.0, reason: 'the plate is full-bleed here too');
  });

  testWidgets('the plate takes its measured height, and the paper follows it',
      (tester) async {
    // What [kAtlasPlateHeight] is worth was measured in the running app, not
    // here: widget tests lay out with Flutter's fixed-width test font, so a
    // pixel claim about where a row's TEXT lands would be a claim about that
    // font. See the constant's doc for the browser numbers and the reasoning.
    //
    // What this pins is font-independent — the plate is exactly that tall, and
    // the chips, the colophon and the index follow it in that order.
    await _pumpAtlas(tester,
        trips: spanningHistory(), surface: const Size(375, 667));

    final plate = tester.getRect(find.byType(FlutterMap));
    expect(plate.height, kAtlasPlateHeight);
    expect(plate.top, lessThan(tester.getRect(find.text('All time')).top));
    expect(tester.getRect(find.text('All time')).bottom,
        lessThanOrEqualTo(tester.getRect(find.text('Traveled')).top));
    expect(tester.getRect(find.text('Traveled')).bottom,
        lessThanOrEqualTo(tester.getRect(find.text('Past trips')).top));
  });

  testWidgets('with no finished trips it offers the way to make some',
      (tester) async {
    // Only reachable by URL — the door is gated on 2+ finished trips — so this
    // is a degrade, not a designed destination.
    await _pumpAtlas(tester, trips: [
      _trip('a', 'Madrid Trip', start: _rel(20), end: _rel(24)),
      _trip('b', 'Someday Trip'),
    ]);

    expect(find.byKey(kAtlasIndexKey), findsNothing);
    expect(find.text('No finished trips yet'), findsOneWidget);
    expect(find.text('Add past trip'), findsOneWidget);
  });

  testWidgets('booting /atlas lands on the atlas inside the shell',
      (tester) async {
    // The importTrip deep-link shape: a zero-argument screen reconstructible
    // from its path, restored onto the Trips tab.
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/atlas';
    addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
    final reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(_FixedTripsApiService(_history())),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue(reports.add),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TravelAtlasScreen), findsOneWidget);
    expect(
      ProviderScope.containerOf(
              tester.element(find.byType(TravelRoutePlannerApp)))
          .read(navIndexProvider),
      AppTab.trips.index,
    );
    expect(reports.last, '/atlas');
  });

  group('year chips', () {
    // Last year's two finished trips, an older year's one, and a trip still
    // ahead — so a year filter has a past row to keep AND a planned pin to
    // keep showing, in the same year.
    final older = _lastYear - 2;
    List<Trip> spanning() => spanningHistory();

    testWidgets('absent when the history spans one year', (tester) async {
      // A lone year chip beside "All time" is chrome that filters nothing.
      await _pumpAtlas(tester, trips: _history());
      expect(find.text('All time'), findsNothing);
      expect(find.text('$_lastYear'), findsNothing);
    });

    testWidgets('present at two years', (tester) async {
      await _pumpAtlas(tester, trips: spanning());
      expect(find.text('All time'), findsOneWidget);
      expect(find.text('$_lastYear'), findsOneWidget);
      expect(find.text('$older'), findsOneWidget);
    });

    testWidgets('years read newest first, after All time', (tester) async {
      await _pumpAtlas(tester, trips: spanning());
      final allTime = tester.getRect(find.text('All time'));
      final newest = tester.getRect(find.text('$_lastYear'));
      final oldest = tester.getRect(find.text('$older'));
      expect(allTime.right, lessThanOrEqualTo(newest.left));
      expect(newest.right, lessThanOrEqualTo(oldest.left));
    });

    testWidgets('picking a year narrows the index, the colophon and the map',
        (tester) async {
      await _pumpAtlas(tester, trips: spanning());
      // All time: everything.
      expect(_inIndex(find.text('Iberia Loop')), findsOneWidget);
      expect(_inIndex(find.text('Athens Trip')), findsOneWidget);
      expect(find.byKey(kAtlasPlannedStatsKey), findsOneWidget);

      await tester.tap(find.text('$older'));
      await tester.pumpAndSettle();

      // Index: only that year's finished trips.
      expect(_inIndex(find.text('Rome Trip')), findsOneWidget);
      expect(_inIndex(find.text('Iberia Loop')), findsNothing);
      // Colophon: degenerates to one group, which the zero-group rule already
      // handles — there is nothing planned in a year that is over.
      expect(find.byKey(kAtlasTraveledStatsKey), findsOneWidget);
      expect(find.byKey(kAtlasPlannedStatsKey), findsNothing);
      // Map: that year's pins only.
      expect(find.byTooltip('Rome · Traveled'), findsOneWidget);
      expect(find.byTooltip('Lisbon · Traveled'), findsNothing);
      expect(find.byTooltip('Madrid · Planned'), findsNothing);
    });

    testWidgets(
        'a filtered year keeps a trip under way on the map, off the index',
        (tester) async {
      // The map is *everywhere*: a year chip narrows it, it does not turn it
      // into the index. A trip that began in that year and is still running is
      // exactly the case where the two rules differ — travelStats counts it,
      // the index must not.
      await _pumpAtlas(tester, trips: [
        ...spanning(),
        _trip('live', 'Naxos Now',
            start: '$_lastYear-12-01', // began last year...
            end: _rel(30), // ...and is not over
            cities: const ['Naxos'],
            pins: const [CityPin(city: 'Naxos', lat: 37.1, lng: 25.4)]),
      ]);
      await tester.tap(find.text('$_lastYear'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Naxos · Traveled'), findsOneWidget);
      expect(_inIndex(find.text('Naxos Now')), findsNothing);
      expect(_inIndex(find.text('Iberia Loop')), findsOneWidget);
    });

    testWidgets('All time restores the full set', (tester) async {
      await _pumpAtlas(tester, trips: spanning());
      await tester.tap(find.text('$older'));
      await tester.pumpAndSettle();
      expect(_inIndex(find.text('Iberia Loop')), findsNothing);

      await tester.tap(find.text('All time'));
      await tester.pumpAndSettle();
      expect(_inIndex(find.text('Iberia Loop')), findsOneWidget);
      expect(_inIndex(find.text('Athens Trip')), findsOneWidget);
      expect(find.byTooltip('Madrid · Planned'), findsOneWidget);
    });

    testWidgets('a year whose trips are all half-dated still lists them',
        (tester) async {
      await _pumpAtlas(tester, trips: [
        ...spanning(),
        _trip('half', 'Split & Hvar',
            end: '${_lastYear - 4}-08-19', cities: const ['Split']),
      ]);
      await tester.tap(find.text('${_lastYear - 4}'));
      await tester.pumpAndSettle();

      expect(_inIndex(find.text('Split & Hvar')), findsOneWidget);
      expect(_inIndex(find.text('0 days')), findsNothing);
    });

    testWidgets('the chips keep the 48px touch floor', (tester) async {
      await _pumpAtlas(tester, trips: spanning());
      for (final label in ['All time', '$_lastYear', '$older']) {
        final chip = find.ancestor(
            of: find.text(label), matching: find.byType(ChoiceChip));
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(48.0),
            reason: '"$label" must clear kMinTouchTarget');
      }
    });
  });

  testWidgets('the trips-list door opens the atlas and back returns to it',
      (tester) async {
    // The door lives in trips_list_screen (its gate is tested beside the band,
    // in trips_list_footprint_test); what is asserted here is the other end of
    // it — openAtlasOnTripsTab needs the shell's tab navigators, so this pumps
    // the real app the way the other tab-push helpers are tested.
    tester.binding.platformDispatcher.defaultRouteNameTestValue =
        kTripsLocation;
    addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
    final reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(_FixedTripsApiService(_history())),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue(reports.add),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(kTravelAtlasSeeAllKey), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(kTravelAtlasSeeAllKey));
    await tester.pumpAndSettle();

    expect(find.byType(TravelAtlasScreen), findsOneWidget);
    expect(reports.last, '/atlas');

    // Back lands on the list it came from, not on a tab root elsewhere.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(TravelAtlasScreen), findsNothing);
    expect(find.byType(TripsListScreen), findsOneWidget);
    expect(reports.last, kTripsLocation);
  });

  testWidgets('the app bar says what the section that opened it says',
      (tester) async {
    await _pumpAtlas(tester, trips: _history());
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.tripsListYourTravels), findsOneWidget);
  });
}
