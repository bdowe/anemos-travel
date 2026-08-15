import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

// The trip page's doors out of a SPINE (specs/shape-before-schedule). The
// planner now leaves the middle of every stay empty until the traveler asks for
// that city, so those days have to render — before this they rendered NOTHING,
// because day sub-headers are derived from the items grouped under a leg.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// No network: the panel renders its seed message and streams nothing.
class _ScriptedPlanService extends PlanService {
  _ScriptedPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {}
}

ItineraryItem _item(int pos, String name, {int? day, String? city}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name, $city',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Lisbon 3n / Porto 2n over Sep 1-6: two places a city, one on the arrival day
/// and one on the day the traveler moves on. Days 2-3 and 5 carry nothing.
Trip _spineTrip({String id = 't-spine'}) => Trip(
      id: id,
      title: 'Iberia',
      startDate: '2026-09-01',
      endDate: '2026-09-06',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Time Out Market', day: 1, city: 'Lisbon'),
        _item(1, 'Pasteis de Belem', day: 4, city: 'Lisbon'),
        _item(2, 'Livraria Lello', day: 4, city: 'Porto'),
      ],
    );

Future<void> _pump(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        tripRefineProvider.overrideWith((ref, tripId) =>
            PlanNotifier(_ScriptedPlanService(), ApiClient(), tripId: tripId)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: TripDetailScreen(tripId: trip.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _refineSeed(WidgetTester tester, String tripId) =>
    ProviderScope.containerOf(tester.element(find.byType(TripDetailScreen)))
        .read(tripRefineProvider(tripId))
        .messages
        .single
        .content;

void main() {
  testWidgets('an empty day inside a city renders and offers to be planned',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _spineTrip());

    // Days 2, 3 (Lisbon) and 5 (Porto) plan nothing. Day 6 is the journey
    // home and is never offered.
    expect(
        find.byKey(const ValueKey('unplanned-day:Lisbon#2')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('unplanned-day:Lisbon#3')), findsOneWidget);
    expect(find.byKey(const ValueKey('unplanned-day:Porto#5')), findsOneWidget);
    expect(find.byKey(const ValueKey('unplanned-day:Porto#6')), findsNothing);

    expect(find.text('Nothing planned yet'), findsNWidgets(3));
    expect(find.text('Plan this day'), findsNWidgets(3));
  });

  testWidgets('empty-day rows sit in day order among the planned days',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _spineTrip());

    double y(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
    // Ascending within Lisbon, and Porto's gap sits below both of Lisbon's —
    // open days interleave with the planned ones rather than piling at the end.
    expect(y('unplanned-day:Lisbon#2'), lessThan(y('unplanned-day:Lisbon#3')));
    expect(y('unplanned-day:Lisbon#3'), lessThan(y('unplanned-day:Porto#5')));
  });

  testWidgets('a dense trip shows no empty-day rows', (tester) async {
    _useTallViewport(tester);
    await _pump(
      tester,
      Trip(
        id: 't-dense',
        title: 'Lisbon',
        startDate: '2026-09-01',
        endDate: '2026-09-03',
        createdAt: '2026-08-01',
        updatedAt: '2026-08-01',
        items: [
          _item(0, 'Time Out Market', day: 1, city: 'Lisbon'),
          _item(1, 'Pasteis de Belem', day: 2, city: 'Lisbon'),
        ],
      ),
    );
    expect(find.text('Nothing planned yet'), findsNothing);
    expect(find.textContaining('unplanned'), findsNothing);
  });

  testWidgets('a city with gaps offers to plan them from its header',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _spineTrip());

    expect(find.text('2 days unplanned'), findsOneWidget); // Lisbon
    expect(find.text('1 day unplanned'), findsOneWidget); // Porto
    expect(find.byKey(const ValueKey('plan-days:Lisbon')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-days:Porto')), findsOneWidget);
  });

  testWidgets('a fully planned city keeps its quiet header', (tester) async {
    _useTallViewport(tester);
    await _pump(
      tester,
      Trip(
        id: 't-quiet',
        title: 'Lisbon',
        startDate: '2026-09-01',
        endDate: '2026-09-03',
        createdAt: '2026-08-01',
        updatedAt: '2026-08-01',
        items: [
          _item(0, 'Time Out Market', day: 1, city: 'Lisbon'),
          _item(1, 'Pasteis de Belem', day: 2, city: 'Lisbon'),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('plan-days:Lisbon')), findsNothing);
    expect(find.text('Plan these days'), findsNothing);
  });

  testWidgets('planning an empty day opens chat scoped to that city',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _spineTrip());

    await tester.tap(find.byKey(const ValueKey('unplanned-day:Lisbon#2')));
    await tester.pumpAndSettle();

    final seed = _refineSeed(tester, 't-spine');
    // A day with no items is not a section the server can replace, so the seed
    // must ask for a CITY-scoped rewrite — scope='day' would be rejected
    // outright ("no itinerary items matched day 2").
    expect(seed, contains("scope='city', city='Lisbon'"));
    expect(seed, isNot(contains("scope='day'")));
    // It names the gap, carries the anchors so a city rewrite keeps them, and
    // proposes before it writes — a seed that carries only a gap has no
    // instruction to apply.
    expect(seed, contains('day 2 has nothing planned'));
    expect(seed, contains('Time Out Market'));
    expect(seed, contains('when I confirm'));
    // The other city is not this job.
    expect(seed, isNot(contains("city='Porto'")));
  });
}
