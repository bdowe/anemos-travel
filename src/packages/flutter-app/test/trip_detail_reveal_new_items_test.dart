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
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

// Content the traveler ASKED FOR is revealed; content that merely arrived is
// not.
//
// Folding a destination used to be a deliberate act, so a refine dropping
// places into a folded city was a corner. Fold-all made it one tap — the
// ordinary posture of anyone surveying a long trip — and a chat that reports
// "added 4 places" while the list does not move is the `_addPlace` no-op bug
// at conversation scale.
//
// The line drawn here: `_refresh` reveals only when a caller ARMED it
// (the refine turn, add-to-trip, add-place). Pull-to-refresh and the
// background status poll do not arm, so a collaborator's edit can never
// unfold a list you deliberately folded.

class _StagedTripsApiService extends TripsApiService {
  Trip current;
  int calls = 0;
  _StagedTripsApiService(this.current)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    calls++;
    return current;
  }
}

/// Emits a scripted event list for one turn, like the chat-panel suites.
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

ItineraryItem _item(int pos, String name, String city, int day,
        {double lat = 0, double lng = 0}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city, Europe',
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: city,
    );

/// Per-city coordinates. Zero for the list-only tests (the screen then skips
/// the map widget entirely); real and DISTINCT for the map test — one shared
/// point is a zero-area bounds and flutter_map asserts on the fit.
const _geo = {
  'Paris': (48.86, 2.33),
  'Rome': (41.89, 12.49),
};

ItineraryItem _geoItem(int pos, String name, String city, int day) {
  final c = _geo[city]!;
  return _item(pos, name, city, day, lat: c.$1, lng: c.$2);
}

/// The base four — Paris (days 1-2) → Rome (days 3-4) — plus whatever [extra]
/// the turn "added", each city's additions kept inside its own run.
List<ItineraryItem> _items(List<ItineraryItem> extra, {bool geo = false}) {
  final make = geo ? _geoItem : _item;
  return [
    make(0, 'Louvre', 'Paris', 1),
    make(1, 'Orsay', 'Paris', 2),
    ...extra.where((e) => e.city == 'Paris'),
    make(2, 'Forum', 'Rome', 3),
    make(3, 'Pantheon', 'Rome', 4),
    ...extra.where((e) => e.city == 'Rome'),
  ];
}

Trip _trip({List<ItineraryItem>? items, bool geo = false}) => Trip(
      id: 't1',
      title: 'Europe',
      startDate: '2026-06-01',
      endDate: '2026-06-04',
      createdAt: '2026-05-01',
      updatedAt: '2026-05-01',
      items: items ?? _items(const [], geo: geo),
    );

class _Harness {
  final _StagedTripsApiService trips;
  final PlanNotifier notifier;
  _Harness(this.trips, this.notifier);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required Trip initial,
  List<PlanEvent> turn = const [PlanEvent(type: 'trip_updated', data: {})],
}) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final trips = _StagedTripsApiService(initial);
  final notifier =
      PlanNotifier(_ScriptedPlanService(turn), ApiClient(), tripId: 't1');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(trips),
        tripRefineProvider.overrideWith((ref, tripId) => notifier),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(trips, notifier);
}

/// Runs one refine turn: the scripted service emits `trip_updated`, which
/// bumps tripUpdateCount and fires the screen's listener.
Future<void> _refineTurn(WidgetTester tester, _Harness h) async {
  await h.notifier.sendMessage('add a few things');
  await tester.pumpAndSettle();
}

Future<void> _foldAll(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Collapse all'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a refine reveals the folded city it added to — and only that one',
      (tester) async {
    final h = await _pump(tester, initial: _trip());
    await _foldAll(tester);
    expect(find.text('Louvre'), findsNothing);
    expect(find.text('Forum'), findsNothing);

    h.trips.current =
        _trip(items: _items([_item(9, 'Trevi', 'Rome', 4)]));
    await _refineTurn(tester, h);

    // The city the turn wrote to is open, with the new place on screen.
    expect(find.text('Trevi'), findsOneWidget,
        reason: 'a place the traveler just asked for must be visible');
    expect(find.text('Pantheon'), findsOneWidget);
    // Paris gained nothing, so it stays exactly as the traveler left it.
    expect(find.text('Louvre'), findsNothing,
        reason: 'revealing must not unfold cities the turn never touched');
  });

  testWidgets('a refine that writes to two folded cities opens both',
      (tester) async {
    // The old reveal stopped at the FIRST new item — correct when _addPlace
    // (exactly one place) was the only caller, silently wrong for a chat that
    // adds across cities. Two additions, two cities: the first-only version
    // leaves the second folded.
    final h = await _pump(tester, initial: _trip());
    await _foldAll(tester);

    h.trips.current = _trip(
        items: _items([
      _item(8, 'Eiffel', 'Paris', 2),
      _item(9, 'Trevi', 'Rome', 4),
    ]));
    await _refineTurn(tester, h);

    expect(find.text('Eiffel'), findsOneWidget);
    expect(find.text('Trevi'), findsOneWidget,
        reason: 'the batch must be revealed whole, not just its first item');
  });

  testWidgets('a refine reveals a folded DAY, not just its city',
      (tester) async {
    // Un-collapsing Rome reveals nothing if the item landed on a day that is
    // itself folded — the same invisibility one level down.
    final h = await _pump(tester, initial: _trip());
    await tester.tap(find.text('Thu, Jun 4')); // fold Rome's day 4 by hand
    await tester.pumpAndSettle();
    expect(find.text('Pantheon'), findsNothing);

    h.trips.current = _trip(items: _items([_item(9, 'Trevi', 'Rome', 4)]));
    await _refineTurn(tester, h);

    expect(find.text('Trevi'), findsOneWidget,
        reason: 'the day the item landed on must open too');
  });

  testWidgets('pull-to-refresh does NOT unfold, even when it brings new items',
      (tester) async {
    // Only content the traveler asked for reveals itself. A collaborator's
    // edit arriving on a routine refresh must leave the fold state alone.
    final h = await _pump(tester, initial: _trip());
    await _foldAll(tester);
    // Back to the default viewport before the fling: a folded four-row list
    // on a 2200px-tall surface leaves the RefreshIndicator nothing to arm
    // against, and the gesture no-ops (the premise assert below catches it).
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpAndSettle();
    final before = h.trips.calls;

    h.trips.current = _trip(items: _items([_item(9, 'Trevi', 'Rome', 4)]));
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(h.trips.calls, greaterThan(before),
        reason: 'premise: the refresh must actually have refetched');
    expect(find.text('Trevi'), findsNothing,
        reason: 'an unasked-for arrival must not unfold the list');
    expect(find.text('Forum'), findsNothing);
  });

  testWidgets('the refine reveal never moves the map', (tester) async {
    // Focusing a leg is _addPlace's alone ("show me the pin I just added").
    // A chat turn writing across cities has no single leg to mean, and
    // dragging the camera mid-conversation is exactly the coupling #358
    // removed.
    final h = await _pump(tester, initial: _trip(geo: true));
    await _foldAll(tester);
    expect(tester.widget<TripMap>(find.byType(TripMap)).fitSignature, isNull,
        reason: 'premise: nothing has focused a leg yet');

    h.trips.current = _trip(
        items: _items([_geoItem(9, 'Trevi', 'Rome', 4)], geo: true));
    await _refineTurn(tester, h);

    expect(find.text('Trevi'), findsOneWidget, reason: 'premise: it revealed');
    expect(tester.widget<TripMap>(find.byType(TripMap)).fitSignature, isNull,
        reason: 'the reveal is list-only — no focus write, no camera move');
  });

  testWidgets('one turn writing three times reveals against the turn start',
      (tester) async {
    // _refresh coalesces several trip_updated events into one trailing pass.
    // The baseline must be the state the TURN began from, not whatever the
    // last event happened to see — otherwise the earlier writes read as
    // "already there" and stay folded.
    final h = await _pump(tester, initial: _trip(), turn: const [
      PlanEvent(type: 'trip_updated', data: {}),
      PlanEvent(type: 'trip_updated', data: {}),
      PlanEvent(type: 'trip_updated', data: {}),
    ]);
    await _foldAll(tester);

    h.trips.current = _trip(
        items: _items([
      _item(8, 'Eiffel', 'Paris', 2),
      _item(9, 'Trevi', 'Rome', 4),
    ]));
    await _refineTurn(tester, h);

    expect(find.text('Eiffel'), findsOneWidget);
    expect(find.text('Trevi'), findsOneWidget);
  });
}
