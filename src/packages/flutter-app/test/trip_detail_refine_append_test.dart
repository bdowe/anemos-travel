import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// A ✨ tap is a change of subject, not a new chat (specs/trip-refine-memory).
/// Before this, every refine entry point but the FAB called reset() first —
/// which is how a conversation vanished when the traveler went back in through
/// the button they had used to start it.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _SilentPlanService extends PlanService {
  _SilentPlanService() : super('http://unused');

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
      address: '$city, Colombia',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip() => Trip(
      id: 't1',
      title: 'Colombia Hop',
      startDate: '2026-08-01',
      endDate: '2026-08-05',
      createdAt: '2026-07-01',
      updatedAt: '2026-07-01',
      items: [
        _item(0, 'Johnny Cay', day: 1, city: 'San Andrés'),
        _item(1, 'Comuna 13', day: 3, city: 'Medellín'),
      ],
    );

Widget _app() => ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(_FakeTripsApiService(_trip())),
        tripRefineProvider.overrideWith((ref, tripId) =>
            PlanNotifier(_SilentPlanService(), ApiClient(), tripId: tripId)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    );

PlanState _refineState(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TripDetailScreen)))
        .read(tripRefineProvider('t1'));

void main() {
  testWidgets('Refine with AI continues the conversation instead of resetting',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(_refineState(tester).messages, hasLength(1));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refine with AI'));
    await tester.pumpAndSettle();

    final messages = _refineState(tester).messages;
    expect(messages, hasLength(2),
        reason: 'the ✨ must append a chapter, not replace the conversation');
    expect(messages.first.displayLabel, isNotNull);
    expect(messages.last.displayLabel, isNotNull);
  });

  testWidgets('the appended seed supersedes the earlier itinerary listing',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(_refineState(tester).messages.first.content, contains('Comuna 13'));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refine with AI'));
    await tester.pumpAndSettle();

    final messages = _refineState(tester).messages;
    // Exactly one authoritative listing is in play.
    expect(messages.first.content, isNot(contains('Comuna 13')));
    expect(messages.first.content, contains('superseded'));
    expect(messages.last.content, contains('Comuna 13'));
    // …and it opens as a change of subject, not a fresh introduction.
    expect(messages.last.content, contains('another part of the same trip'));
    expect(messages.last.content, isNot(contains('Start by asking')));
  });

  testWidgets('the panel header follows the newest context chip',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Trip assistant'), findsWidgets);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refine with AI'));
    await tester.pumpAndSettle();

    // The header is derived, so it is right even though no screen field holds
    // the target any more.
    expect(find.text('Refining Whole trip'), findsWidgets);
  });
}
