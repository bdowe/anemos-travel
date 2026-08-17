import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/budget.dart';
import 'package:travel_route_planner/models/expense.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/services/accommodations_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/budget_api_service.dart';
import 'package:travel_route_planner/services/transport_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/budget_provider.dart';
import 'package:travel_route_planner/providers/transport_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';
import 'package:travel_route_planner/widgets/booking_sheets.dart';
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

class _FakeBudgetApiService extends BudgetApiService {
  final List<Expense> expenses;
  final double? targetAmount;
  _FakeBudgetApiService({this.expenses = const [], this.targetAmount})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Budget> getBudget(String tripId) async => Budget(
        targetAmount: targetAmount,
        currency: 'USD',
        spent: expenses.fold<double>(0, (s, e) => s + e.amount),
      );

  @override
  Future<List<Expense>> listExpenses(String tripId) async => expenses;
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
    WidgetTester tester, Trip trip,
    {BudgetApiService? budget}) async {
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
        // Un-overridden, the budget providers fail (no network in widget
        // tests) — the owner's Budget tab renders regardless (presence must
        // not depend on load state), a viewer's does not.
        if (budget != null) budgetApiServiceProvider.overrideWithValue(budget),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return (todosApi, accApi);
}

/// Taps the Bookings header tab; when [count] is given, first pins the
/// booked-progress pill riding the tab ('1/2' etc.) — the counter is a
/// [StatusPill] beside the label now, not part of it (dropped entirely on
/// narrow; these tests run wide at 800). Pass no count for a trip whose
/// todos are empty (viewer trips included): the tab renders bare.
Future<void> _openBookingsTab(WidgetTester tester, [String? count]) async {
  if (count != null) {
    expect(
        find.descendant(
            of: find.byType(StatusPill), matching: find.text(count)),
        findsOneWidget);
  }
  await tester.tap(find.text('Bookings'));
  await tester.pumpAndSettle();
}

/// Taps a destination chip in the Bookings filter strip. The strip scrolls
/// horizontally (that is the point of it), so a chip past the fold has to be
/// brought into view before it can be hit — exactly what a traveler does with
/// a drag.
Future<void> _tapDestination(WidgetTester tester, String label) async {
  final chip = find.ancestor(
      of: find.text(label), matching: find.byType(ChoiceChip));
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
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

    await _openBookingsTab(tester, '1/2');
    await tester.tap(find.widgetWithText(FilterChip, 'Not booked yet'));
    await tester.pumpAndSettle();

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

  testWidgets(
      'unbooked scope with nothing left to book celebrates; the selected '
      'chip is the way back to every booking', (tester) async {
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

    await _openBookingsTab(tester, '1/1');
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Not booked yet'));
    await tester.pumpAndSettle();

    expect(find.text("Everything's booked"), findsOneWidget);
    expect(find.byType(BookingTodoRow), findsNothing);
    // The scope chip renders selected above the celebration — the explicit
    // why, and the one-tap path back to the full bookings list.
    expect(
        tester
            .widget<FilterChip>(
                find.widgetWithText(FilterChip, 'Not booked yet'))
            .selected,
        isTrue);
    await tester.tap(find.widgetWithText(FilterChip, 'Not booked yet'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        findsOneWidget);
    expect(find.text("Everything's booked"), findsNothing);
  });

  // ——— The Bookings view: trip-wide, booked and unbooked, filterable by
  // destination, entered from the Bookings header tab; the 'Not booked yet'
  // scope chip inside it narrows to the left-to-book list.

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

  testWidgets('the Bookings tab shows booked and unbooked, no item tiles',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    await _openBookingsTab(tester, '1/2');

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

    await _openBookingsTab(tester, '1/2');
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

  testWidgets('destination chips narrow the lens; the All chip is the way back',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, twoCityTrip());

    await _openBookingsTab(tester, '0/2');
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);

    await _tapDestination(tester, 'Rome');
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsNothing);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);

    // Re-tapping the selected chip is a dead gesture, not a hidden clear —
    // the filter is still on Rome.
    await _tapDestination(tester, 'Rome');
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsNothing);

    // The All chip is the visible way back to every booking.
    await _tapDestination(tester, 'All');
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

    await _openBookingsTab(tester, '0/2');
    expect(
        find.widgetWithText(BookingTodoCard, 'Museum tickets'), findsOneWidget);

    // A destination chip hides the residual (it matched no destination)...
    await _tapDestination(tester, 'Paris');
    expect(find.widgetWithText(BookingTodoCard, 'Museum tickets'),
        findsNothing);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);

    // ...and the Other chip shows only residuals.
    await _tapDestination(tester, 'Other bookings');
    expect(
        find.widgetWithText(BookingTodoCard, 'Museum tickets'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsNothing);
  });

  testWidgets(
      'the counted Bookings tab opens the bookings view; the Itinerary tab '
      'is the way back', (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    // Pill '1/2' — one booked custom todo of two todos. The count rides
    // the tab as a StatusPill (this tab replaced the old one-way counter).
    await _openBookingsTab(tester, '1/2');

    expect(find.text('Louvre'), findsNothing);
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    // The selected tab is bold; the unselected one isn't.
    expect(tester.widget<Text>(find.text('Bookings')).style?.fontWeight,
        FontWeight.w700);
    expect(tester.widget<Text>(find.text('Itinerary')).style?.fontWeight,
        FontWeight.w500);

    // The friction this feature fixes: leaving is one visible tap.
    await tester.tap(find.text('Itinerary'));
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Itinerary')).style?.fontWeight,
        FontWeight.w700);
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

    await _openBookingsTab(tester, '0/2');
    expect(find.widgetWithText(ChoiceChip, 'Paris'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Paris'));
    await tester.pumpAndSettle();
    expect(
        find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsNothing);
  });

  testWidgets(
      'viewers get an un-counted Bookings tab that opens detail rows',
      (tester) async {
    _useTallViewport(tester);
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Paris',
          access: 'viewer',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: [_item(0, 'Louvre')],
          accommodations: const [
            Accommodation(id: 'acc1', name: 'Hotel Lutetia', address: 'Paris'),
          ],
        ));

    // No todos (the server withholds them from viewers) — the tab label
    // carries no count.
    expect(find.textContaining('booked'), findsNothing);

    await _openBookingsTab(tester);
    expect(
        find.widgetWithText(BookingDetailRow, 'Hotel Lutetia'), findsOneWidget);
    expect(find.text('Louvre'), findsNothing);
  });

  testWidgets(
      'Bookings tab with no bookings shows its empty state; the tabs stay '
      'and lead back out', (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _trip());

    await _openBookingsTab(tester);
    expect(find.text('No bookings yet'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    // No scope chip in the nothing-at-all state — scoping an empty list is
    // meaningless; the tabs are the escape.
    expect(find.byType(FilterChip), findsNothing);

    // The trap regression this feature exists to prevent: the way out stays
    // visible even when the view is empty.
    await tester.tap(find.text('Itinerary'));
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsOneWidget);
  });

  // ——— The Bookings view's single add CTA: one "+ Add booking" menu in the
  // header (the view's "Add place"), which replaced the itinerary-tail
  // Add stay / Add transport / Add booking trio.

  testWidgets(
      'the header add CTA swaps per view: Add place on the itinerary, the '
      'Add-booking menu in the Bookings view', (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    // Itinerary: Add place only — the old tail trio is gone.
    expect(find.text('Add place'), findsOneWidget);
    expect(find.text('Add booking'), findsNothing);
    expect(find.text('Add stay'), findsNothing);
    expect(find.text('Add transport'), findsNothing);

    // Bookings view: the swap, not an addition.
    await _openBookingsTab(tester, '1/2');
    expect(find.text('Add booking'), findsOneWidget);
    expect(find.text('Add place'), findsNothing);

    await tester.tap(find.text('Add booking'));
    await tester.pumpAndSettle();
    expect(find.text('Stay'), findsOneWidget);
    expect(find.text('Transport'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
  });

  testWidgets(
      'the add menu routes to the stay sheet, the segment sheet, and the '
      'custom-booking dialog', (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());
    await _openBookingsTab(tester, '1/2');

    Future<void> pick(String item) async {
      await tester.tap(find.text('Add booking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    await pick('Stay');
    expect(find.byType(AddStaySheet), findsOneWidget);
    await tester.tapAt(const Offset(20, 20)); // barrier-dismiss the sheet
    await tester.pumpAndSettle();

    await pick('Transport');
    expect(find.byType(AddSegmentSheet), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // The custom-booking dialog class is private; its title is the marker.
    await pick('Other');
    expect(find.text('Add a booking'), findsOneWidget);
  });

  testWidgets("the 'Not booked yet' scope keeps the add menu",
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    await _openBookingsTab(tester, '1/2');
    await tester.tap(find.widgetWithText(FilterChip, 'Not booked yet'));
    await tester.pumpAndSettle();
    expect(find.text('Add booking'), findsOneWidget);
  });

  testWidgets('re-tapping the selected Itinerary tab is a no-op',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Café de Flore'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Itinerary')).style?.fontWeight,
        FontWeight.w700);

    await tester.tap(find.text('Itinerary'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Café de Flore'), findsOneWidget);
  });

  testWidgets(
      "the 'Not booked yet' scope keeps the Bookings tab selected",
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip());

    await _openBookingsTab(tester, '1/2');
    await tester.tap(find.widgetWithText(FilterChip, 'Not booked yet'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'),
        findsOneWidget);
    expect(tester.widget<Text>(find.text('Bookings')).style?.fontWeight,
        FontWeight.w700);

    // Itinerary exits the whole Bookings view, scope included.
    await tester.tap(find.text('Itinerary'));
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsOneWidget);
  });

  // ── Budget tab (third header tab; selection derives from _itemFilter) ──

  testWidgets('the Budget tab selects and swaps the body for the budget view',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip(),
        budget: _FakeBudgetApiService(
            expenses: const [
              Expense(id: 'e1', category: 'lodging', label: 'Hotel', amount: 80)
            ],
            targetAmount: 200));

    await tester.tap(find.text('Budget'));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.text('Budget')).style?.fontWeight,
        FontWeight.w700);
    expect(find.text('Hotel'), findsOneWidget);
    // The city groups are swapped out. (Wear & pack left the body for the
    // app-bar icon — its title text appears in NEITHER view now; the
    // positive Budget-view icon pin lives in trip_detail_wear_section_test.)
    expect(find.text('Louvre'), findsNothing);
    expect(find.text('What to wear & pack'), findsNothing);
  });

  testWidgets('the owner Budget tab renders even when the budget load fails',
      (tester) async {
    _useTallViewport(tester);
    // No budget override: both providers error. The tab must not pop in and
    // out with load state for an editor.
    await _pump(tester, mixedTrip());
    expect(find.text('Budget'), findsOneWidget);
  });

  testWidgets('the Budget tab round-trips back to the full itinerary',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip(), budget: _FakeBudgetApiService());

    await tester.tap(find.text('Budget'));
    await tester.pumpAndSettle();
    expect(find.text('No budget yet'), findsOneWidget);
    expect(find.text('Louvre'), findsNothing);

    await tester.tap(find.text('Itinerary'));
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Café de Flore'), findsOneWidget);
  });

  testWidgets('re-tapping the selected Budget tab is a no-op',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, mixedTrip(), budget: _FakeBudgetApiService());

    await tester.tap(find.text('Budget'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budget'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('No budget yet'), findsOneWidget);
  });

  testWidgets('viewer with an empty budget gets no Budget tab',
      (tester) async {
    _useTallViewport(tester);
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Paris',
          access: 'viewer',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: [_item(0, 'Louvre')],
        ),
        budget: _FakeBudgetApiService());

    expect(find.text('Budget'), findsNothing);
  });

  testWidgets('viewer with expenses gets a read-only Budget tab',
      (tester) async {
    _useTallViewport(tester);
    await _pump(
        tester,
        Trip(
          id: 't1',
          title: 'Paris',
          access: 'viewer',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: [_item(0, 'Louvre')],
        ),
        budget: _FakeBudgetApiService(expenses: const [
          Expense(id: 'e1', category: 'food', label: 'Dinner', amount: 45)
        ]));

    await tester.tap(find.text('Budget'));
    await tester.pumpAndSettle();

    expect(find.text('Dinner'), findsOneWidget);
    expect(find.byTooltip('Add expense'), findsNothing);
    expect(find.byTooltip('Set budget target'), findsNothing);
  });
}
