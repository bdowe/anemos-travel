import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Replays a canned event list; no network.
class _ScriptedPlanService extends PlanService {
  final List<PlanEvent> events;

  _ScriptedPlanService(this.events) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final e in events) {
      yield e;
    }
  }
}

ItineraryItem _item(int pos, String name, {int? day, String? city}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city, Colombia',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip({String? access}) => Trip(
      id: 't1',
      title: 'Colombia Hop',
      status: 'planned',
      startDate: '2026-08-01',
      endDate: '2026-08-05',
      createdAt: '2026-07-01',
      updatedAt: '2026-07-01',
      access: access,
      items: [
        _item(0, 'Johnny Cay', day: 1, city: 'San Andrés'),
        _item(1, 'Comuna 13', day: 3, city: 'Medellín'),
      ],
    );

Widget _app(Trip trip) => ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        tripRefineProvider.overrideWith((ref, tripId) => PlanNotifier(
            _ScriptedPlanService(const []), ApiClient(),
            tripId: tripId)),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    );

PlanState _refineState(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TripDetailScreen)))
        .read(tripRefineProvider('t1'));

void main() {
  testWidgets('chat FAB opens the Trip assistant with a whole-trip seed',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_trip()));
    await tester.pumpAndSettle();

    final fab = find.byType(FloatingActionButton);
    expect(fab, findsOneWidget);

    await tester.tap(fab);
    await tester.pumpAndSettle();

    // Panel is open under the assistant framing; the FAB yields to it.
    expect(find.text('Trip assistant'), findsWidgets);
    expect(find.byType(FloatingActionButton), findsNothing);

    // The seed is a single user message carrying the full itinerary and the
    // question-friendly closing, bound for the trip-scoped session.
    final messages = _refineState(tester).messages;
    expect(messages, hasLength(1));
    expect(messages.single.content, contains('Colombia Hop'));
    expect(messages.single.content, contains('Johnny Cay'));
    expect(messages.single.content, contains('Comuna 13'));
    expect(messages.single.content, contains('also just ask questions'));
  });

  testWidgets('FAB is hidden for viewers', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_trip(access: 'viewer')));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('FAB shows for editor co-planners (specs/collaborator-refine)',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_trip(access: 'editor')));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('reopening via the FAB resumes the conversation, not a reset',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_trip()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    final seeded = _refineState(tester).messages.length;
    expect(seeded, greaterThan(0));

    // Close the panel; the conversation lives on in the keepAlive provider.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);

    // Reopen: same conversation, no fresh seed.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Trip assistant'), findsWidgets);
    expect(_refineState(tester).messages.length, seeded);
  });
}
