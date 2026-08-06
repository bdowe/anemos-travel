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
/// on the trip survive); setBooked calls are recorded.
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
  _FakeAccommodationsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Accommodation> update(
      String tripId, String accId, Map<String, dynamic> body) async {
    updates.add((accId, body));
    return Accommodation(id: accId, name: 'x');
  }
}

class _FakeTransportApiService extends TransportApiService {
  _FakeTransportApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripSegment> updateSegment(
          String tripId, String segmentId, Map<String, dynamic> body) async =>
      TripSegment(id: segmentId, mode: 'flight');
}

ItineraryItem _item(int pos, String name,
        {String? category = 'attraction', String? localSourceName}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: 'Paris, France',
      latitude: 0,
      longitude: 0,
      category: category,
      day: 1,
      city: 'Paris',
      localSourceName: localSourceName,
    );

Trip _trip({
  List<ItineraryItem>? items,
  List<BookingTodo>? todos,
  List<Accommodation>? accommodations,
  List<TripSegment>? segments,
}) =>
    Trip(
      id: 't1',
      title: 'Paris',
      status: 'planned',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: items ??
          [
            _item(0, 'Louvre'),
            _item(1, 'Café de Flore',
                category: 'restaurant', localSourceName: 'Ana'),
          ],
      bookingTodos: todos,
      accommodations: accommodations,
      segments: segments,
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<(_FakeBookingTodosApiService, _FakeAccommodationsApiService)> _pump(
    WidgetTester tester, Trip trip) async {
  final todosApi = _FakeBookingTodosApiService();
  final accApi = _FakeAccommodationsApiService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider.overrideWithValue(todosApi),
        accommodationsApiServiceProvider.overrideWithValue(accApi),
        transportApiServiceProvider
            .overrideWithValue(_FakeTransportApiService()),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return (todosApi, accApi);
}

Future<void> _selectFilter(WidgetTester tester, String label) async {
  await tester.tap(find.byIcon(Icons.filter_list));
  await tester.pumpAndSettle();
  // Tap the menu item, not its Text: the checked item's label can sit under
  // the check-mark overlay, which trips tap()'s hit-test warning.
  await tester.tap(find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is CheckedPopupMenuItem)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("Locals' picks lens shows only credited items", (tester) async {
    _useTallViewport(tester);
    await _pump(
        tester,
        _trip(todos: const [
          BookingTodo(
              id: 'td-stay',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris'),
        ]));

    // Unfiltered view: both items plus the inline booking row.
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Café de Flore'), findsOneWidget);
    expect(find.byType(BookingTodoRow), findsOneWidget);

    await _selectFilter(tester, "Locals' picks");

    // Only the credited item survives; booking rows hide like any places lens.
    expect(find.text('Café de Flore'), findsOneWidget);
    expect(find.text('Louvre'), findsNothing);
    expect(find.byType(BookingTodoRow), findsNothing);
  });

  testWidgets(
      'unbooked lens lists only unbooked booking rows and no item tiles',
      (tester) async {
    _useTallViewport(tester);
    final (todosApi, accApi) = await _pump(
        tester,
        _trip(
          todos: const [
            BookingTodo(
                id: 'td-stay',
                kind: 'stay',
                todoKey: 'stay:paris',
                title: 'Stay in Paris'),
            BookingTodo(
                id: 'td-done',
                kind: 'other',
                todoKey: 'custom:1',
                title: 'Museum pass',
                booked: true),
          ],
          accommodations: const [
            Accommodation(id: 'acc1', name: 'Hotel Lutetia', address: 'Paris'),
          ],
          segments: const [
            TripSegment(
                id: 'seg1',
                mode: 'flight',
                origin: 'JFK',
                destination: 'Paris',
                booked: true),
          ],
        ));

    await _selectFilter(tester, 'Not booked yet');

    // Places are swapped out for the left-to-book rows.
    expect(find.text('Louvre'), findsNothing);
    expect(find.text('Café de Flore'), findsNothing);
    // The unbooked stay todo (with its matched confirmed stay's details)
    // stays; the booked custom todo and the booked arrival leg drop out.
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        findsOneWidget);
    expect(find.widgetWithText(BookingDetailRow, 'Hotel Lutetia'),
        findsOneWidget);
    expect(find.text('Museum pass'), findsNothing);
    expect(find.textContaining('JFK'), findsNothing);

    // Checking the box runs the same lockstep writer as the inline view and
    // the now-booked row leaves the lens, revealing the all-booked state.
    await tester.tap(find.descendant(
        of: find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(todosApi.bookedCalls, [('td-stay', true)]);
    expect(accApi.updates, hasLength(1));
    expect(find.byType(BookingTodoRow), findsNothing);
    expect(find.text("Everything's booked"), findsOneWidget);
  });

  testWidgets('unbooked lens with nothing left to book celebrates',
      (tester) async {
    _useTallViewport(tester);
    await _pump(
        tester,
        _trip(todos: const [
          BookingTodo(
              id: 'td-stay',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris',
              booked: true),
        ]));

    await _selectFilter(tester, 'Not booked yet');

    expect(find.text("Everything's booked"), findsOneWidget);
    expect(find.byType(BookingTodoRow), findsNothing);
  });

  // ——— The 'All bookings' lens: trip-wide, booked and unbooked, filterable
  // by destination, entered from the filter menu or the tappable counter.

  /// The unbooked-lens fixture: an unbooked stay todo with a matched
  /// confirmed stay, a BOOKED custom todo, and a BOOKED matched arrival
  /// segment — the booked halves are what this lens shows and 'Not booked
  /// yet' hides.
  Trip mixedTrip() => _trip(
        todos: const [
          BookingTodo(
              id: 'td-stay',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris'),
          BookingTodo(
              id: 'td-done',
              kind: 'other',
              todoKey: 'custom:1',
              title: 'Museum pass',
              booked: true),
        ],
        accommodations: const [
          Accommodation(id: 'acc1', name: 'Hotel Lutetia', address: 'Paris'),
        ],
        segments: const [
          TripSegment(
              id: 'seg1',
              mode: 'flight',
              origin: 'JFK',
              destination: 'Paris',
              booked: true),
        ],
      );

  Trip twoCityTrip({List<BookingTodo>? todos}) => _trip(
        items: [
          ItineraryItem(
            id: 'i0',
            position: 0,
            name: 'Louvre',
            address: 'Paris, France',
            latitude: 0,
            longitude: 0,
            category: 'attraction',
            day: 1,
            city: 'Paris',
          ),
          ItineraryItem(
            id: 'i1',
            position: 1,
            name: 'Colosseum',
            address: 'Rome, Italy',
            latitude: 0,
            longitude: 0,
            category: 'attraction',
            day: 2,
            city: 'Rome',
          ),
        ],
        todos: todos ??
            const [
              BookingTodo(
                  id: 'td-paris',
                  kind: 'stay',
                  todoKey: 'stay:paris',
                  title: 'Stay in Paris'),
              BookingTodo(
                  id: 'td-rome',
                  kind: 'stay',
                  todoKey: 'stay:rome',
                  title: 'Stay in Rome'),
            ],
      );

  testWidgets('all-bookings lens shows booked and unbooked, no item tiles',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    await _selectFilter(tester, 'All bookings');

    expect(find.text('Louvre'), findsNothing);
    expect(find.text('Café de Flore'), findsNothing);
    // Unbooked todo + its matched stay's details.
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(
        find.widgetWithText(BookingDetailRow, 'Hotel Lutetia'), findsOneWidget);
    // The booked residual card and the booked matched arrival stay visible —
    // the contrast with 'Not booked yet', which drops both.
    expect(find.widgetWithText(BookingTodoCard, 'Museum pass'), findsOneWidget);
    expect(find.textContaining('JFK'), findsWidgets);
  });

  testWidgets(
      'checking a row in the all-bookings lens runs the lockstep writer '
      'and the row stays put', (tester) async {
    _useTallViewport(tester);
    final (todosApi, accApi) = await _pump(tester, mixedTrip());

    await _selectFilter(tester, 'All bookings');
    await tester.tap(find.descendant(
        of: find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();

    expect(todosApi.bookedCalls, [('td-stay', true)]);
    expect(accApi.updates, hasLength(1));
    // Unlike the unbooked lens, the row does not leave the list and no
    // celebration replaces it.
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(find.text("Everything's booked"), findsNothing);
  });

  testWidgets('destination chips narrow the lens; re-tap returns to All',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, twoCityTrip());

    await _selectFilter(tester, 'All bookings');
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Rome'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsNothing);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);

    // Tapping the selected chip clears back to All.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Rome'));
    await tester.pumpAndSettle();
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);
  });

  testWidgets('residual bookings show only under All and the Other chip',
      (tester) async {
    _useTallViewport(tester);
    await _pump(
        tester,
        twoCityTrip(todos: const [
          BookingTodo(
              id: 'td-paris',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris'),
          BookingTodo(
              id: 'td-custom',
              kind: 'other',
              todoKey: 'custom:1',
              title: 'Museum tickets',
              auto: false),
        ]));

    await _selectFilter(tester, 'All bookings');
    expect(
        find.widgetWithText(BookingTodoCard, 'Museum tickets'), findsOneWidget);

    // A destination chip hides the residual (it matched no destination)...
    await tester.tap(find.widgetWithText(ChoiceChip, 'Paris'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(BookingTodoCard, 'Museum tickets'),
        findsNothing);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);

    // ...and the Other chip shows only residuals.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Other bookings'));
    await tester.pumpAndSettle();
    expect(
        find.widgetWithText(BookingTodoCard, 'Museum tickets'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsNothing);
  });

  testWidgets('tapping the booked counter jumps into the all-bookings lens',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    // '1 of 2 booked' — one booked custom todo of two todos.
    await tester.tap(find.text('1 of 2 booked'));
    await tester.pumpAndSettle();

    expect(find.text('Louvre'), findsNothing);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
  });

  testWidgets('a revisited city gets one destination chip covering its runs',
      (tester) async {
    _useTallViewport(tester);
    // Paris → Rome → Paris: three runs, two 'Paris' labels, ONE Paris chip.
    await _pump(
        tester,
        _trip(
          items: [
            for (final (i, spec) in const [
              ('Louvre', 'Paris', 1),
              ('Colosseum', 'Rome', 2),
              ('Orsay', 'Paris', 3),
            ].indexed)
              ItineraryItem(
                id: 'i$i',
                position: i,
                name: spec.$1,
                address: '${spec.$1} street, ${spec.$2}, Country',
                latitude: 0,
                longitude: 0,
                category: 'attraction',
                day: spec.$3,
                city: spec.$2,
              ),
          ],
          todos: const [
            BookingTodo(
                id: 'td-paris',
                kind: 'stay',
                todoKey: 'stay:paris',
                title: 'Stay in Paris'),
            BookingTodo(
                id: 'td-rome',
                kind: 'stay',
                todoKey: 'stay:rome',
                title: 'Stay in Rome'),
          ],
        ));

    await _selectFilter(tester, 'All bookings');
    expect(find.widgetWithText(ChoiceChip, 'Paris'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Paris'));
    await tester.pumpAndSettle();
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsNothing);
  });

  testWidgets('viewers reach the lens from the menu; no counter, detail rows',
      (tester) async {
    _useTallViewport(tester);
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Paris',
          status: 'planned',
          access: 'viewer',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: [_item(0, 'Louvre')],
          accommodations: const [
            Accommodation(id: 'acc1', name: 'Hotel Lutetia', address: 'Paris'),
          ],
        ));

    // No todos (the server withholds them from viewers) — no counter.
    expect(find.textContaining('booked'), findsNothing);

    await _selectFilter(tester, 'All bookings');
    expect(
        find.widgetWithText(BookingDetailRow, 'Hotel Lutetia'), findsOneWidget);
    expect(find.text('Louvre'), findsNothing);
  });

  testWidgets('all-bookings lens with no bookings shows its empty state',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _trip());

    await _selectFilter(tester, 'All bookings');
    expect(find.text('No bookings yet'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
  });
}
