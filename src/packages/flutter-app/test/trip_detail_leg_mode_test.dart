import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

// Per-leg transport mode: the header pill is gone; each transport row carries
// a mode menu whose override is server-preserved (BookingTodo.mode) and beats
// the derived default on every re-derivation.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// The provider a resolved mode implies — the fake's copy of the server's
/// transportModeLink (booking_todo_handler.go).
String? _providerForMode(String mode) => switch (mode) {
      'ferry' => 'ferry',
      'flight' => 'google_flights',
      'car' || 'train' || 'bus' => 'rome2rio',
      _ => null,
    };

/// Mimics the server's booking-todo contract: syncTodos upserts the derived
/// payload, but `mode` (like `booked`) only ever comes from the fake's own
/// preserved map — a sync can never write it — and the row's provider comes
/// from the SERVER's resolution, not from the posted guess.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  /// Server-preserved per-row override, keyed by todo_key.
  final Map<String, String> modes;

  /// What the SERVER derives for a leg (leg_transport_mode.go), keyed by
  /// todo_key. Like the real sync handler, it — not the posted provider —
  /// decides the stored provider: what the client posts is only its
  /// pre-sync bootstrap guess.
  final Map<String, String> derivedModes;
  List<Map<String, dynamic>>? lastDerived;
  final List<({String todoId, String mode, String origin, String destination})>
      setModeCalls = [];

  _FakeBookingTodosApiService(
      {Map<String, String>? modes, Map<String, String>? derivedModes})
      : modes = modes ?? {},
        derivedModes = derivedModes ?? {},
        super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
      String tripId, List<Map<String, dynamic>> derived) async {
    lastDerived = derived;
    return [
      for (final d in derived)
        () {
          final key = d['todo_key'] as String;
          final derivedMode = derivedModes[key];
          final effective = modes[key] ?? derivedMode;
          return BookingTodo(
            id: key,
            kind: d['kind'] as String,
            todoKey: key,
            title: d['title'] as String,
            subtitle: d['subtitle'] as String?,
            provider: effective == null
                ? d['provider'] as String?
                : (_providerForMode(effective) ?? d['provider'] as String?),
            departDate: d['depart_date'] as String?,
            mode: modes[key],
            derivedMode: derivedMode,
            position: d['position'] as int? ?? 0,
          );
        }(),
    ];
  }

  @override
  Future<BookingTodo> setMode(
    String tripId,
    String todoId, {
    required String mode,
    required String origin,
    required String destination,
    String? departDate,
    int passengers = 1,
  }) async {
    setModeCalls.add(
        (todoId: todoId, mode: mode, origin: origin, destination: destination));
    modes[todoId] = mode; // fixtures use todo_key as id
    return BookingTodo(
      id: todoId,
      kind: 'transport',
      todoKey: todoId,
      title: '$origin → $destination',
      provider: switch (mode) {
        'ferry' => 'ferry',
        'flight' => 'google_flights',
        _ => 'rome2rio',
      },
      mode: mode,
    );
  }
}

ItineraryItem _item(int pos, String name, String address, String city,
        {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: address,
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

/// [legMode] seeds the override on the trip payload's own todo row — the
/// production shape: GET /trips serializes booking_todos.mode, so the boot
/// derivation sees it before the first sync. [legDerivedMode] does the same
/// for the server's own derivation (booking_todos.derived_mode, 00068).
Trip _twoCityTrip(
        {String? access,
        String? travelMode,
        String? legMode,
        String? legDerivedMode}) =>
    Trip(
      id: 't1',
      title: 'Europe',
      startDate: '2026-06-10',
      endDate: '2026-06-13',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      access: access,
      travelMode: travelMode,
      items: [
        _item(0, 'Louvre', 'Paris, France', 'Paris', day: 1),
        _item(1, 'Colosseum', 'Rome, Italy', 'Rome', day: 3),
      ],
      bookingTodos: [
        _todoLeg('transport:paris>>rome', 'Paris → Rome',
            mode: legMode, derivedMode: legDerivedMode),
      ],
    );

BookingTodo _todoLeg(String key, String title,
        {String? mode, String? derivedMode}) =>
    BookingTodo(
        id: key,
        kind: 'transport',
        todoKey: key,
        title: title,
        mode: mode,
        derivedMode: derivedMode,
        provider: derivedMode == null ? null : _providerForMode(derivedMode));

// Wide enough that the body clears kRailBreakpoint (full open-labels, not the
// compact short ones), tall enough that the lazily-built bookings rows exist.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<_FakeBookingTodosApiService> _pump(WidgetTester tester, Trip trip,
    {Map<String, String>? modes, Map<String, String>? derivedModes}) async {
  final todosApi =
      _FakeBookingTodosApiService(modes: modes, derivedModes: derivedModes);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider.overrideWithValue(todosApi),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: trip.id)),
    ),
  );
  await tester.pumpAndSettle();
  return todosApi;
}

Finder _rowModeMenu() => find.descendant(
    of: find.byType(BookingTodoRow),
    matching: find.byIcon(Icons.arrow_drop_down));

void main() {
  testWidgets('header shows no trip-wide travel-mode pill',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    // Even with a stored travel_mode, nothing in the header names it — mode
    // is per-leg now (and the pill's l10n keys are gone).
    await _pump(tester, _twoCityTrip(travelMode: 'mixed'));

    expect(find.text('Mixed modes'), findsNothing);
    expect(find.byTooltip('Travel mode'), findsNothing);
    // The status pill is retired too (specs/retire-trip-status) — the date
    // chip is the only meta chip left beside Refine.
    expect(find.text('Draft'), findsNothing);
  });

  testWidgets('row mode menu PATCHes the override and the row link flips',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final todosApi = await _pump(tester, _twoCityTrip());

    // The derived flight leg starts on Find flights with a mode menu.
    expect(find.textContaining('Find flights'), findsOneWidget);
    expect(_rowModeMenu(), findsOneWidget);

    await tester.tap(_rowModeMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('train'));
    await tester.pumpAndSettle();

    expect(todosApi.setModeCalls, hasLength(1));
    final call = todosApi.setModeCalls.single;
    expect(call.mode, 'train');
    expect(call.origin, 'Paris');
    expect(call.destination, 'Rome');

    // The re-derivation echoed the override: the leg is ground now, so its
    // action is the Rome2Rio link, not Find flights.
    expect(todosApi.lastDerived, isNotNull);
    final leg = todosApi.lastDerived!
        .singleWhere((d) => d['todo_key'] == 'transport:paris>>rome');
    expect(leg['provider'], 'rome2rio');
    expect(find.textContaining('Find flights'), findsNothing);
    expect(find.textContaining('Rome2Rio'), findsOneWidget);
  });

  testWidgets('a preserved override beats the derived default on load',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    // The server already holds mode=train for the leg; the boot sync must
    // derive it as ground (rome2rio), not fall back to the flight default.
    final todosApi = await _pump(tester, _twoCityTrip(legMode: 'train'),
        modes: {'transport:paris>>rome': 'train'});

    final leg = todosApi.lastDerived!
        .singleWhere((d) => d['todo_key'] == 'transport:paris>>rome');
    expect(leg['provider'], 'rome2rio');
    expect(find.textContaining('Find flights'), findsNothing);
    expect(find.textContaining('Rome2Rio'), findsOneWidget);
  });

  testWidgets("a ground trip's leg menu checks the trip's own mode",
      (WidgetTester tester) async {
    _useTallViewport(tester);
    // No per-leg override: the leg is derived as ground, and 'rome2rio' alone
    // can't say which ground mode. Before the trip was consulted this menu
    // opened with nothing checked on a trip that plainly stated it drives.
    await _pump(tester, _twoCityTrip(travelMode: 'car'));

    await tester.tap(_rowModeMenu());
    await tester.pumpAndSettle();

    final checked = find.ancestor(
      of: find.byIcon(Icons.check),
      matching: find.widgetWithText(Row, 'car'),
    );
    expect(checked, findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('a ferry override on a non-Greek leg gets Find ferries',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final todosApi = await _pump(tester, _twoCityTrip(legMode: 'ferry'),
        modes: {'transport:paris>>rome': 'ferry'});

    final leg = todosApi.lastDerived!
        .singleWhere((d) => d['todo_key'] == 'transport:paris>>rome');
    expect(leg['provider'], 'ferry');
    expect(find.textContaining('Find ferries'), findsOneWidget);
  });

  // 00068: geography reaches the row through booking_todos.derived_mode. The
  // Italy case that started this — Rome → Florence offering a flight search
  // for a 1h35 train — is these three tests.

  testWidgets("the server's derived mode makes the leg ground on load",
      (WidgetTester tester) async {
    _useTallViewport(tester);
    // Nobody chose anything: derived_mode alone (the server's geography rung)
    // must move the leg off the flight default.
    final todosApi = await _pump(tester, _twoCityTrip(legDerivedMode: 'train'),
        derivedModes: {'transport:paris>>rome': 'train'});

    final leg = todosApi.lastDerived!
        .singleWhere((d) => d['todo_key'] == 'transport:paris>>rome');
    expect(leg['provider'], 'rome2rio');
    expect(find.textContaining('Find flights'), findsNothing);
    expect(find.textContaining('Rome2Rio'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(BookingTodoRow),
            matching: find.byIcon(Icons.train)),
        findsOneWidget);
  });

  testWidgets("a chosen mode still beats the server's derivation",
      (WidgetTester tester) async {
    _useTallViewport(tester);
    // The traveler said flight on a leg geography called a train. The
    // override is the top rung, so the row stays a flight.
    final todosApi = await _pump(
        tester, _twoCityTrip(legMode: 'flight', legDerivedMode: 'train'),
        modes: {'transport:paris>>rome': 'flight'},
        derivedModes: {'transport:paris>>rome': 'train'});

    final leg = todosApi.lastDerived!
        .singleWhere((d) => d['todo_key'] == 'transport:paris>>rome');
    expect(leg['provider'], 'google_flights');
    expect(find.textContaining('Find flights'), findsOneWidget);
    expect(find.textContaining('Rome2Rio'), findsNothing);
  });

  testWidgets("the sync response's derivation reaches the row it is on",
      (WidgetTester tester) async {
    _useTallViewport(tester);
    // A trip whose page has never synced carries no derived_mode, so the
    // bootstrap default posts a flight — and the server answers "train". The
    // row must follow WITHOUT a reload: its tap target comes from the
    // _flightLegs registry the derivation fills, so a row that only relabelled
    // would still open the in-app flight search.
    final todosApi = await _pump(tester, _twoCityTrip(),
        derivedModes: {'transport:paris>>rome': 'train'});

    // What it posted was the bootstrap guess...
    expect(
        todosApi.lastDerived!.singleWhere(
            (d) => d['todo_key'] == 'transport:paris>>rome')['provider'],
        'google_flights');
    // ...and what it shows is the server's answer.
    expect(find.textContaining('Find flights'), findsNothing);
    expect(find.textContaining('Rome2Rio'), findsOneWidget);
  });

  testWidgets('read-only viewers get the plain icon, no mode menu',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    await _pump(tester, _twoCityTrip(access: 'viewer'));

    expect(find.byType(BookingTodoRow), findsWidgets);
    expect(_rowModeMenu(), findsNothing);
  });
}
