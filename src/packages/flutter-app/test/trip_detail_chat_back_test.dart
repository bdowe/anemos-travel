import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:travel_route_planner/widgets/trip_refine_panel.dart';

import 'support/l10n_test_app.dart';

/// Back closes the trip's chat before it leaves the trip
/// (specs/trip-refine-memory). The panel is drawn inside the screen rather
/// than pushed as a route, so before this back threw away the whole page —
/// the reported friction.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  int getTripCalls = 0;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    getTripCalls++;
    return trip;
  }
}

/// Emits [events], then waits on [gate] before emitting [tailEvents] — so a
/// test can press back mid-turn and let the rest of the stream land afterwards.
/// Never completing [gate] leaves the turn hanging in flight.
class _ScriptedPlanService extends PlanService {
  final List<PlanEvent> events;
  final Completer<void>? gate;
  final List<PlanEvent> tailEvents;

  _ScriptedPlanService(this.events, {this.gate, this.tailEvents = const []})
      : super('http://unused');

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
    if (gate != null) {
      await gate!.future;
      for (final e in tailEvents) {
        yield e;
      }
    }
  }
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

const _homeKey = Key('home-placeholder');

/// Pushes the trip over a placeholder home, so a real pop is observable.
Widget _app(
  _FakeTripsApiService api, {
  List<PlanEvent> events = const [],
  Completer<void>? gate,
  List<PlanEvent> tailEvents = const [],
}) =>
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(api),
        tripRefineProvider.overrideWith((ref, tripId) => PlanNotifier(
            _ScriptedPlanService(events, gate: gate, tailEvents: tailEvents),
            ApiClient(),
            tripId: tripId)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            key: _homeKey,
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const TripDetailScreen(tripId: 't1'))),
                child: const Text('open trip'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _openTripAndChat(WidgetTester tester) async {
  await tester.tap(find.text('open trip'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
  expect(find.byType(TripRefinePanel), findsOneWidget);
}

Future<bool> _back(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator)).maybePop();

PlanState _refineState(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TripDetailScreen)))
        .read(tripRefineProvider('t1'));

void main() {
  testWidgets('back closes the chat panel and keeps the trip on screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();
    await _openTripAndChat(tester);
    final seeded = _refineState(tester).messages.length;
    expect(seeded, greaterThan(0));

    expect(await _back(tester), isTrue);
    await tester.pumpAndSettle();

    expect(find.byType(TripRefinePanel), findsNothing);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    // The conversation is untouched — closing is not discarding.
    expect(_refineState(tester).messages.length, seeded);
  });

  // Closing the panel is the same gesture that used to discard whatever was
  // half-typed in it: the body's slot changes runtime type, so the subtree —
  // composer included — is re-inflated. The transcript already survived this;
  // the question being written did not.
  testWidgets('closing and reopening keeps the half-typed question',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();
    await _openTripAndChat(tester);

    await tester.enterText(find.byType(TextField), 'why not Utrecht instead?');
    expect(await _back(tester), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(TripRefinePanel), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'why not Utrecht instead?',
    );
  });

  // Same re-inflation, no gesture at all: the panel crosses 900px and the body
  // swaps Stack for Row underneath it.
  testWidgets('resizing across the docked width keeps it too',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();
    await _openTripAndChat(tester);
    expect(find.byType(VerticalDivider), findsNothing); // sheet, not docked

    await tester.enterText(find.byType(TextField), 'and the ferry times?');
    tester.view.physicalSize = const Size(1400, 1000);
    await tester.pumpAndSettle();
    expect(find.byType(VerticalDivider), findsOneWidget); // now docked

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'and the ferry times?',
    );
  });

  testWidgets('a second back leaves the trip, conversation intact',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();
    await _openTripAndChat(tester);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(TripDetailScreen)));
    final seeded = container.read(tripRefineProvider('t1')).messages.length;

    expect(await _back(tester), isTrue);
    await tester.pumpAndSettle();
    expect(await _back(tester), isTrue);
    await tester.pumpAndSettle();

    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.byKey(_homeKey), findsOneWidget);
    // keepAlive family: leaving the page does not drop the conversation.
    expect(container.read(tripRefineProvider('t1')).messages.length, seeded);
  });

  testWidgets('the app-bar back arrow closes the panel before the screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();
    await _openTripAndChat(tester);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(TripRefinePanel), findsNothing);
    expect(find.byType(TripDetailScreen), findsOneWidget);
  });

  testWidgets('back closes the docked panel exactly like the sheet',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();
    await _openTripAndChat(tester);
    expect(find.byType(VerticalDivider), findsOneWidget); // docked

    expect(await _back(tester), isTrue);
    await tester.pumpAndSettle();

    expect(find.byType(TripRefinePanel), findsNothing);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(find.byType(TripDetailScreen), findsOneWidget);
  });

  testWidgets('back mid-stream closes the panel without aborting the turn',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    await tester.pumpWidget(_app(
      _FakeTripsApiService(_trip()),
      events: const [
        PlanEvent(type: 'text_delta', data: {'text': 'Working'})
      ],
      gate: gate,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_refineState(tester).isStreaming, isTrue);
    expect(await _back(tester), isTrue);
    await tester.pump();

    expect(find.byType(TripRefinePanel), findsNothing);
    // Still running behind the closed panel, and the FAB says so — otherwise
    // an accidental back reads as "did that kill it?".
    expect(_refineState(tester).isStreaming, isTrue);
    expect(
        find.descendant(
            of: find.byType(FloatingActionButton),
            matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a trip_updated landing after the panel closed still refreshes',
      (WidgetTester tester) async {
    // The listener used to live inside TripRefinePanel; closing the panel
    // mid-turn would then have silently dropped the reload, and the itinerary
    // would sit there stale after an edit the agent really made.
    final gate = Completer<void>();
    final api = _FakeTripsApiService(_trip());
    await tester.pumpWidget(_app(
      api,
      events: const [
        PlanEvent(type: 'text_delta', data: {'text': 'On it'})
      ],
      gate: gate,
      tailEvents: const [
        PlanEvent(type: 'trip_updated', data: {'trip_id': 't1'})
      ],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(await _back(tester), isTrue);
    // pump, not pumpAndSettle: the turn is still in flight, so the FAB's
    // progress indicator never settles.
    await tester.pump();
    final before = api.getTripCalls;

    // The patch lands with the panel already gone.
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.getTripCalls, greaterThan(before));
  });

  testWidgets('Escape closes the panel', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FakeTripsApiService(_trip())));
    await tester.pumpAndSettle();
    await _openTripAndChat(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(TripRefinePanel), findsNothing);
    expect(find.byType(TripDetailScreen), findsOneWidget);
  });
}
