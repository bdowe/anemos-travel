import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

/// An overnight flight occupies two calendar days. EWR → Amsterdam departs the
/// 23rd and lands the 24th, and the trip page had exactly one slot to say so —
/// which it filled with the ARRIVAL day and labelled `depart_date`.
///
/// That single wrong date reached four places: the row's own text, the
/// Find-flights link (in-app prefill and the server-built search_url), the
/// Add-details prefill, and the Trips-list "first leg departs" nudge
/// (MIN(booking_todos.depart_date)). All four are downstream of the posted
/// depart_date, so all four are fixed by correcting it at the source.
///
/// The fact itself lives on trip_segments — the only table in the schema that
/// models depart + arrive — and the derived row defers to its matched confirmed
/// segment, exactly as it already defers for transport MODE.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _CapturingBookingTodosApiService extends BookingTodosApiService {
  final List<List<Map<String, dynamic>>> syncedPayloads = [];
  _CapturingBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
      String tripId, List<Map<String, dynamic>> derived) async {
    syncedPayloads.add(derived);
    throw Exception('offline test env');
  }
}

/// Echoes the derived payload back as saved rows, the way the server does, so
/// the checklist actually renders and the row widgets can be inspected.
class _EchoingBookingTodosApiService extends BookingTodosApiService {
  _EchoingBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      [
        for (var i = 0; i < derived.length; i++)
          BookingTodo(
            id: 'todo-$i',
            kind: derived[i]['kind'] as String,
            todoKey: derived[i]['todo_key'] as String,
            title: derived[i]['title'] as String,
            subtitle: derived[i]['subtitle'] as String?,
            provider: derived[i]['provider'] as String?,
            departDate: derived[i]['depart_date'] as String?,
            returnDate: derived[i]['return_date'] as String?,
            position: derived[i]['position'] as int,
          ),
      ];
}

class _FakePrefsApi implements PreferencesApiService {
  _FakePrefsApi(this.homeAirport);
  String homeAirport;

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async =>
      TravelerPreferences(homeAirport: homeAirport);

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
    String? fitnessRoutine,
    String? outdoorIntensity,
    String? companions,
  }) async =>
      TravelerPreferences(homeAirport: this.homeAirport);
}

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city address',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

TripSegment _segment({
  required String id,
  String? origin,
  String? destination,
  String? departDate,
  String? arriveDate,
  bool auto = false,
}) =>
    TripSegment(
      id: id,
      mode: 'flight',
      origin: origin,
      destination: destination,
      departDate: departDate,
      arriveDate: arriveDate,
      auto: auto,
    );

void main() {
  // Amsterdam Aug 24 – Aug 26, then Rome. The traveler's real outbound flight
  // leaves EWR on the 23rd.
  Trip makeTrip({List<TripSegment>? segments}) => Trip(
        id: 't1',
        title: 'Amsterdam',
        startDate: '2026-08-24',
        endDate: '2026-08-28',
        createdAt: '2026-08-01',
        updatedAt: '2026-08-01',
        segments: segments,
        items: [
          _item(0, 'Rijksmuseum', 'Amsterdam', day: 1),
          _item(1, 'Anne Frank House', 'Amsterdam', day: 3),
          _item(2, 'Colosseum', 'Rome', day: 4),
          _item(3, 'Pantheon', 'Rome', day: 5),
        ],
      );

  Future<List<Map<String, dynamic>>> derive(
      WidgetTester tester, Trip trip) async {
    final fake = _CapturingBookingTodosApiService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider.overrideWithValue(fake),
          preferencesApiServiceProvider.overrideWithValue(_FakePrefsApi('EWR')),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.syncedPayloads, isNotEmpty);
    return fake.syncedPayloads.last;
  }

  Map<String, dynamic> leg(List<Map<String, dynamic>> derived, String key) =>
      derived.singleWhere((t) => t['todo_key'] == key);

  testWidgets(
      'with no recorded flight, the outbound leg says what it knows — the '
      'ARRIVAL day — instead of implying a departure', (tester) async {
    final derived = await derive(tester, makeTrip());
    final outbound = leg(derived, 'transport:ewr>>amsterdam');

    // A bare "Aug 24" under "EWR → Amsterdam" has exactly one reading: this is
    // the day you fly. For a transatlantic red-eye that reading is false, and
    // nothing on screen let the traveler discover the app never knew.
    expect(outbound['subtitle'], 'Arrives Aug 24');

    // The wire is deliberately UNCHANGED in this case: depart_date is the
    // search seed behind "Find flights", and dropping it would strip the date
    // from a link on the most-used row in the app to buy purity in a field
    // nobody reads. A search date is a query; the subtitle is the assertion.
    expect(outbound['depart_date'], '2026-08-24');
  });

  testWidgets('a confirmed overnight segment gives the outbound leg both dates',
      (tester) async {
    final derived = await derive(
      tester,
      makeTrip(segments: [
        _segment(
          id: 's1',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-23',
          arriveDate: '2026-08-24',
        ),
      ]),
    );
    final outbound = leg(derived, 'transport:ewr>>amsterdam');

    expect(outbound['subtitle'], 'Aug 23 → Aug 24');
    // The load-bearing half: this is what the server rebuilds search_url from,
    // what seeds the in-app flight search, what pre-fills Add-details, and what
    // the Trips-list "first leg departs" nudge reads via MIN(depart_date).
    expect(outbound['depart_date'], '2026-08-23');
  });

  testWidgets('a same-day segment keeps the single-date shape', (tester) async {
    final derived = await derive(
      tester,
      makeTrip(segments: [
        _segment(
          id: 's1',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-24',
          arriveDate: '2026-08-24',
        ),
      ]),
    );

    expect(leg(derived, 'transport:ewr>>amsterdam')['subtitle'], 'Aug 24');
  });

  testWidgets('a segment with only a departure shows just that date',
      (tester) async {
    final derived = await derive(
      tester,
      makeTrip(segments: [
        _segment(
          id: 's1',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-23',
        ),
      ]),
    );

    expect(leg(derived, 'transport:ewr>>amsterdam')['subtitle'], 'Aug 23');
  });

  testWidgets(
      'the outbound leg is the only one whose itinerary date is an arrival',
      (tester) async {
    // The asymmetry, pinned: for an inter-city or return leg the itinerary's
    // date genuinely IS a departure — you leave a city on its last day — so
    // those rows keep today's bare single date and today's wire value. Only
    // the outbound has no preceding leg to supply one.
    final derived = await derive(tester, makeTrip());

    final interCity = leg(derived, 'transport:amsterdam>>rome');
    expect(interCity['subtitle'], isNot(contains('Arrives')));
    expect(interCity['subtitle'], isNot(contains('→')));

    final home = leg(derived, 'transport:rome>>ewr');
    expect(home['subtitle'], isNot(contains('Arrives')));
    expect(home['subtitle'], isNot(contains('→')));
    expect(home['depart_date'], '2026-08-28');
  });

  testWidgets('an auto (suggested) segment is not treated as a recorded fact',
      (tester) async {
    // Booking drafts write auto segments. A suggestion is a proposal, not
    // something the traveler told us — it must not date the row.
    final derived = await derive(
      tester,
      makeTrip(segments: [
        _segment(
          id: 's1',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-23',
          arriveDate: '2026-08-24',
          auto: true,
        ),
      ]),
    );

    expect(
        leg(derived, 'transport:ewr>>amsterdam')['subtitle'], 'Arrives Aug 24');
    expect(
        leg(derived, 'transport:ewr>>amsterdam')['depart_date'], '2026-08-24');
  });

  testWidgets('only one segment dates a leg when several match the same city',
      (tester) async {
    // Claim-once, from the matcher this now reuses rather than reimplements:
    // the first candidate wins the slot and the rest stay unclaimed, so a
    // second Amsterdam-bound segment cannot also retitle a row. Because
    // _deriveTodos reads the SAME claim result the rendered rows do, the posted
    // payload and the screen can never disagree about which leg owns it.
    final derived = await derive(
      tester,
      makeTrip(segments: [
        _segment(
          id: 's1',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-23',
          arriveDate: '2026-08-24',
        ),
        _segment(
          id: 's2',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-20',
          arriveDate: '2026-08-21',
        ),
      ]),
    );

    final dated = derived
        .where((t) => t['kind'] == 'transport')
        .where((t) => (t['subtitle'] as String?)?.contains('→') ?? false)
        .toList();
    expect(dated, hasLength(1));
    expect(dated.single['todo_key'], 'transport:ewr>>amsterdam');
    // The FIRST candidate won — the loser's dates appear nowhere.
    expect(dated.single['subtitle'], 'Aug 23 → Aug 24');
    expect(dated.single['depart_date'], '2026-08-23');
  });

  // Two pumpWidget calls in ONE test reuse the same State, so _load never
  // re-runs and the second case silently inspects the first case's screen.
  // These are deliberately separate tests for that reason.
  testWidgets('"Add details…" stays offered while no segment fills the slot',
      (tester) async {
    final row = await _outboundRow(tester, _tripWithAirports());
    expect(row.todo.subtitle, 'Arrives Aug 24');
    expect(row.onAddDetails, isNotNull);
  });

  testWidgets('"Add details…" disappears once a segment fills the slot',
      (tester) async {
    // Now that the row shows its segment's dates, offering "Add details…" as
    // well would open a sheet pre-filled with that segment's own dates whose
    // Save creates a SECOND segment for the same leg. Same rule the mode
    // picker already follows: that row's truth is the segment, edited via its
    // own sheet.
    final row = await _outboundRow(
      tester,
      _tripWithAirports(segments: [
        _segment(
          id: 's1',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-23',
          arriveDate: '2026-08-24',
        ),
      ]),
    );
    expect(row.todo.subtitle, 'Aug 23 → Aug 24',
        reason: 'the derivation did not see the segment at all');
    expect(row.onAddDetails, isNull);
  });
}

/// The trip carries its OWN airports so the two home legs do not depend on the
/// async preferences load resolving before the first render.
Trip _tripWithAirports({List<TripSegment>? segments}) => Trip(
      id: 't1',
      title: 'Amsterdam',
      startDate: '2026-08-24',
      endDate: '2026-08-28',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      originAirport: 'EWR',
      returnAirport: 'EWR',
      segments: segments,
      items: [
        _item(0, 'Rijksmuseum', 'Amsterdam', day: 1),
        _item(1, 'Anne Frank House', 'Amsterdam', day: 3),
        _item(2, 'Colosseum', 'Rome', day: 4),
        _item(3, 'Pantheon', 'Rome', day: 5),
      ],
    );

/// Renders the checklist for real — the echoing service hands the derived
/// payload back as saved rows the way the server does — and returns the
/// outbound home leg's row widget.
Future<BookingTodoRow> _outboundRow(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_EchoingBookingTodosApiService()),
        preferencesApiServiceProvider.overrideWithValue(_FakePrefsApi('EWR')),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final rows = tester.widgetList<BookingTodoRow>(find.byType(BookingTodoRow));
  return rows.firstWhere((r) => r.todo.title == 'EWR → Amsterdam',
      orElse: () => throw StateError(
          'no outbound row among: ${rows.map((r) => r.todo.title).toList()}'));
}
