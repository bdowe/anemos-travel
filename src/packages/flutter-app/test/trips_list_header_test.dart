import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/shared_with_me_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

/// The always-on "Upcoming" section chrome: header + "New trip" action
/// regardless of resumable-chats state (before, the header only rendered
/// beside a Continue section), the payload-only stat chips on plain cards,
/// and the aggregate stats line that appears from two upcoming trips on.
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
        {String? start, String? end, List<String>? cities, String? access}) =>
    Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      cities: cities,
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Upcoming header and New trip render with zero resumable chats',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip', start: _rel(10), end: _rel(13)),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('New trip'), findsOneWidget);
  });

  testWidgets('New trip switches to the Plan tab',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', 'Lisbon Trip', start: _rel(10), end: _rel(13)),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('New trip'));
    await tester.pump();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(TripsListScreen)));
    expect(container.read(navIndexProvider), AppTab.plan.index);
  });

  testWidgets(
      'all-past accounts keep the Upcoming header — it is the list\'s only '
      'create affordance', (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('past', 'Old Trip', start: _rel(-9), end: _rel(-2)),
    ]);
    await tester.pumpAndSettle();

    // Deliberate: the header renders whenever the account owns ANY trip,
    // even with zero upcoming cards under it, so "New trip" never vanishes.
    // A future gate on groups.upcoming.isNotEmpty would silently strip the
    // create affordance from exactly the accounts most in need of it.
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('New trip'), findsOneWidget);
    expect(find.text('Past trips'), findsOneWidget);
  });

  testWidgets('shared-only accounts get no Upcoming header',
      (WidgetTester tester) async {
    await _pumpList(tester, shared: [
      _trip('s1', 'Shared Trip',
          start: _rel(10), end: _rel(13), access: 'editor'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Upcoming'), findsNothing);
    expect(find.text('New trip'), findsNothing);
    expect(find.text('Shared Trip'), findsOneWidget);
  });

  testWidgets('plain cards carry duration and city-count chips',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      // Soonest → promoted to the hero; the chip assertions target the
      // second trip's plain card.
      _trip('hero', 'Weekend Hop', start: _rel(5), end: _rel(6)),
      _trip('t2', 'Big Summer Adventure',
          start: _rel(40),
          end: _rel(73), // 34-day span
          cities: const [
            'Prague', 'Kraków', 'Vienna', 'Budapest', 'Ljubljana',
            'Zagreb', 'Split', 'Athens', 'Naxos', // 9 cities
          ]),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('34 days'), findsOneWidget);
    expect(find.text('9 cities'), findsOneWidget);
  });

  testWidgets('a single-city trip shows no city-count chip',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('hero', 'Weekend Hop', start: _rel(5), end: _rel(6)),
      _trip('t2', 'City Break',
          start: _rel(40), end: _rel(42), cities: const ['Lisbon']),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('1 city'), findsNothing);
    // The cities line still names it under the title.
    expect(find.text('Lisbon'), findsOneWidget);
  });

  testWidgets(
      'the upcoming-only stats line is gone — lifetime stats moved into the '
      '"Your travels" band (specs/trips-page-insights)',
      (WidgetTester tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', 'Weekend Hop',
          start: _rel(5), end: _rel(6), cities: const ['Porto']), // 2 days
      _trip('t2', 'City Break',
          start: _rel(40), end: _rel(42), cities: const ['Lisbon']), // 3 days
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('upcoming trip'), findsNothing);
    // The all-time band carries the aggregate now: 2 trips, 5 travel days,
    // 2 cities — as tiles (value and label are separate Texts).
    expect(find.text('Your travels'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Travel days'), findsOneWidget);
  });
}
