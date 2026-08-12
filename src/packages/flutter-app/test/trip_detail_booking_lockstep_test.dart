import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/services/accommodations_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/transport_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/transport_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Sync fails (mirroring the screen's swallow-on-error, so the todos seeded
/// on the trip survive); setBooked calls are recorded and optionally fail.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  final List<(String, bool)> bookedCalls = [];
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');

  @override
  Future<BookingTodo> setBooked(
      String tripId, String todoId, bool booked) async {
    bookedCalls.add((todoId, booked));
    return BookingTodo(
        id: todoId, kind: 'stay', todoKey: 'k', title: 't', booked: booked);
  }
}

class _FakeAccommodationsApiService extends AccommodationsApiService {
  final List<(String, Map<String, dynamic>)> updates = [];
  final bool failUpdate;
  _FakeAccommodationsApiService({this.failUpdate = false})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Accommodation> update(
      String tripId, String accId, Map<String, dynamic> body) async {
    updates.add((accId, body));
    if (failUpdate) throw Exception('server said no');
    return Accommodation(id: accId, name: 'x');
  }
}

class _FakeTransportApiService extends TransportApiService {
  final List<(String, Map<String, dynamic>)> updates = [];
  _FakeTransportApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripSegment> updateSegment(
      String tripId, String segmentId, Map<String, dynamic> body) async {
    updates.add((segmentId, body));
    return TripSegment(id: segmentId, mode: 'flight');
  }
}

ItineraryItem _item(int pos, String name, {int? day}) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: 'Paris, France',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: 'Paris',
    );

const _stayTodo = BookingTodo(
    id: 'td-stay', kind: 'stay', todoKey: 'stay:paris', title: 'Stay in Paris');

const _confirmedStay = Accommodation(
  id: 'acc1',
  name: 'Hotel Lutetia',
  address: 'Paris',
  provider: 'Booking.com',
  checkIn: '2026-06-10',
  checkOut: '2026-06-12',
);

const _confirmedLeg = TripSegment(
  id: 'seg1',
  mode: 'flight',
  origin: 'JFK',
  destination: 'Paris',
  departDate: '2026-06-10',
  provider: 'Delta',
);

Trip _trip({String? access, List<BookingTodo>? todos}) => Trip(
      id: 't1',
      title: 'Paris',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      access: access,
      items: [_item(0, 'Louvre', day: 1), _item(1, 'Café de Flore', day: 2)],
      bookingTodos: todos,
      accommodations: const [_confirmedStay],
      segments: const [_confirmedLeg],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<
    (
      _FakeBookingTodosApiService,
      _FakeAccommodationsApiService,
      _FakeTransportApiService
    )> _pump(WidgetTester tester, Trip trip, {bool failStayUpdate = false}) async {
  final todosApi = _FakeBookingTodosApiService();
  final accApi = _FakeAccommodationsApiService(failUpdate: failStayUpdate);
  final transportApi = _FakeTransportApiService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider.overrideWithValue(todosApi),
        accommodationsApiServiceProvider.overrideWithValue(accApi),
        transportApiServiceProvider.overrideWithValue(transportApi),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return (todosApi, accApi, transportApi);
}

void main() {
  testWidgets(
      'matched confirmed records render as detail rows under the todo rows',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _trip(todos: const [_stayTodo]));

    // The stay todo row with its matched confirmed stay's details beneath.
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    final detail = find.widgetWithText(BookingDetailRow, 'Hotel Lutetia');
    expect(detail, findsOneWidget);
    expect(tester.getTopLeft(find.text('Hotel Lutetia')).dy,
        greaterThan(tester.getTopLeft(find.text('Stay in Paris')).dy));

    // Matched rows carry no own checkbox — the todo row's checkbox drives
    // both flags.
    expect(
        find.descendant(of: detail, matching: find.byType(Checkbox)),
        findsNothing);

    // The confirmed arrival leg matched by destination renders too (no
    // arrival todo here — sync is down — so it's a standalone detail row
    // WITH its own checkbox).
    final legDetail = find.widgetWithText(BookingDetailRow, 'JFK → Paris');
    expect(legDetail, findsOneWidget);
    expect(
        find.descendant(of: legDetail, matching: find.byType(Checkbox)),
        findsOneWidget);
  });

  testWidgets('checking a matched todo row PATCHes todo AND record',
      (tester) async {
    _useTallViewport(tester);
    final (todosApi, accApi, _) =
        await _pump(tester, _trip(todos: const [_stayTodo]));

    final row = find.widgetWithText(BookingTodoRow, 'Stay in Paris');
    await tester.tap(
        find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();

    expect(todosApi.bookedCalls, [('td-stay', true)]);
    expect(accApi.updates, hasLength(1));
    expect(accApi.updates.single.$1, 'acc1');
    expect(accApi.updates.single.$2, {'booked': true});
    // Optimistic strike-through on the detail row too (record flipped).
    final detailTitle = tester.widget<Text>(find.text('Hotel Lutetia'));
    expect(detailTitle.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('a failed record PATCH rolls back todo and record together',
      (tester) async {
    _useTallViewport(tester);
    final (todosApi, accApi, _) = await _pump(
        tester, _trip(todos: const [_stayTodo]),
        failStayUpdate: true);

    final row = find.widgetWithText(BookingTodoRow, 'Stay in Paris');
    await tester.tap(
        find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();

    // Both writes were attempted...
    expect(todosApi.bookedCalls, [('td-stay', true)]);
    expect(accApi.updates, hasLength(1));
    // ...but the failure rolled the whole row back.
    final todoCheckbox = tester.widget<Checkbox>(
        find.descendant(of: row, matching: find.byType(Checkbox)));
    expect(todoCheckbox.value, isFalse);
    final detailTitle = tester.widget<Text>(find.text('Hotel Lutetia'));
    expect(detailTitle.style?.decoration, isNot(TextDecoration.lineThrough));
    expect(find.textContaining('Update failed'), findsOneWidget);
  });

  testWidgets('viewers see confirmed details inline, read-only',
      (tester) async {
    _useTallViewport(tester);
    // Viewer follows get no todos from the server; confirmed records render
    // as standalone detail rows inside the itinerary.
    await _pump(tester, _trip(access: 'viewer', todos: null));

    expect(find.byType(BookingTodoRow), findsNothing);
    final stayDetail = find.widgetWithText(BookingDetailRow, 'Hotel Lutetia');
    expect(stayDetail, findsOneWidget);
    expect(find.widgetWithText(BookingDetailRow, 'JFK → Paris'), findsOneWidget);

    // Checkbox shows state but is disabled; no edit/delete affordances.
    final checkbox = tester.widget<Checkbox>(
        find.descendant(of: stayDetail, matching: find.byType(Checkbox)));
    expect(checkbox.onChanged, isNull);
    expect(
        find.descendant(
            of: stayDetail, matching: find.byIcon(Icons.edit_outlined)),
        findsNothing);
    // No add actions for viewers either.
    expect(find.text('Add booking'), findsNothing);
  });
}
