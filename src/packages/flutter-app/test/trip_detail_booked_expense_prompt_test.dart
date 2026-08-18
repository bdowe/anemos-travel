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
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

/// Budget autopopulate on the booked flip (specs/budget-v2 PR B): the checkbox
/// harness is cloned from trip_detail_booking_lockstep_test.dart with a
/// stateful budget fake recording add/delete calls.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

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

/// Stateful: holds the expense list so provider invalidation after a mutation
/// reflects it; records adds (with their source link) and deletes.
class _FakeBudgetApiService extends BudgetApiService {
  final List<Expense> expenses;
  final List<Map<String, dynamic>> addCalls = [];
  final List<String> deletedIds = [];

  _FakeBudgetApiService([List<Expense> seed = const []])
      : expenses = List.of(seed),
        super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Budget> getBudget(String tripId) async => Budget(
        currency: 'EUR',
        spent: expenses.fold<double>(0, (s, e) => s + e.amount),
      );

  @override
  Future<List<Expense>> listExpenses(String tripId) async => List.of(expenses);

  @override
  Future<Expense> addExpense(String tripId,
      {required String category,
      required String label,
      required double amount,
      bool planned = false,
      String? sourceKind,
      String? sourceId,
      String? legKey,
      bool legPlan = false}) async {
    addCalls.add({
      'category': category,
      'label': label,
      'amount': amount,
      'planned': planned,
      'source_kind': sourceKind,
      'source_id': sourceId,
    });
    final e = Expense(
        id: 'new-${addCalls.length}',
        category: category,
        label: label,
        amount: amount,
        // A booked flip records a PAYMENT (00067) — the prompt never plans.
        actualAmount: planned ? null : amount,
        plannedAmount: planned ? amount : null,
        purchased: !planned,
        auto: sourceKind != null,
        sourceKind: sourceKind,
        sourceId: sourceId);
    expenses.add(e);
    return e;
  }

  @override
  Future<void> deleteExpense(String tripId, String expenseId) async {
    deletedIds.add(expenseId);
    expenses.removeWhere((e) => e.id == expenseId);
  }
}

ItineraryItem _item(int pos, String name) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: 'Paris, France',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: 1,
      city: 'Paris',
    );

const _confirmedStay = Accommodation(
  id: 'acc1',
  name: 'Hotel Lutetia',
  address: 'Paris',
  checkIn: '2026-06-10',
  checkOut: '2026-06-12',
);

Trip _trip({List<BookingTodo>? todos, List<Accommodation>? accommodations}) =>
    Trip(
      id: 't1',
      title: 'Paris',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [_item(0, 'Louvre')],
      bookingTodos: todos,
      accommodations: accommodations ?? const [_confirmedStay],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<(_FakeBookingTodosApiService, _FakeBudgetApiService)> _pump(
    WidgetTester tester, Trip trip,
    {List<Expense> seedExpenses = const []}) async {
  final todosApi = _FakeBookingTodosApiService();
  final budgetApi = _FakeBudgetApiService(seedExpenses);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider.overrideWithValue(todosApi),
        accommodationsApiServiceProvider
            .overrideWithValue(_FakeAccommodationsApiService()),
        transportApiServiceProvider
            .overrideWithValue(_FakeTransportApiService()),
        budgetApiServiceProvider.overrideWithValue(budgetApi),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return (todosApi, budgetApi);
}

Future<void> _tickRow(WidgetTester tester, String title) async {
  final row = find.widgetWithText(BookingTodoRow, title);
  await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
  await tester.pumpAndSettle();
}

const _stayTodo = BookingTodo(
    id: 'td-stay', kind: 'stay', todoKey: 'stay:paris', title: 'Stay in Paris');

void main() {
  testWidgets(
      'ticking a matched stay opens the prompt; Save adds a linked expense '
      'with an Undo snackbar', (tester) async {
    _useTallViewport(tester);
    final (_, budgetApi) = await _pump(tester, _trip(todos: const [_stayTodo]));

    await _tickRow(tester, 'Stay in Paris');

    // The dialog: confirmed stay wins the prefill (lodging + its name),
    // amount labeled with the budget currency.
    expect(find.text('Add to budget?'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Hotel Lutetia'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Amount (EUR)'), '150');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(budgetApi.addCalls, hasLength(1));
    expect(budgetApi.addCalls.single, {
      'category': 'lodging',
      'label': 'Hotel Lutetia',
      'amount': 150.0,
      // A booked flip records a PAYMENT, never a plan (00067) — the server's
      // linked path refuses a plan-only add outright.
      'planned': false,
      // The link rides the most durable row: the confirmed stay, not the todo.
      'source_kind': 'accommodation',
      'source_id': 'acc1',
    });
    // Confirmation snackbar with Undo; Undo deletes the created expense.
    expect(find.textContaining('added to Budget'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(budgetApi.deletedIds, ['new-1']);
  });

  testWidgets('Skip adds nothing', (tester) async {
    _useTallViewport(tester);
    final (_, budgetApi) = await _pump(tester, _trip(todos: const [_stayTodo]));

    await _tickRow(tester, 'Stay in Paris');
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(budgetApi.addCalls, isEmpty);
    expect(find.text('Add to budget?'), findsNothing);
  });

  testWidgets('a row whose booking is already in the budget never re-prompts',
      (tester) async {
    _useTallViewport(tester);
    final (_, budgetApi) = await _pump(
      tester,
      _trip(todos: const [_stayTodo]),
      // A taken-over (auto=false) expense linked to the stay: the traveler
      // owns it — re-booking must neither prompt nor touch it.
      seedExpenses: const [
        Expense(
            id: 'e1',
            category: 'lodging',
            label: 'Hotel Lutetia',
            amount: 150,
            auto: false,
            sourceKind: 'accommodation',
            sourceId: 'acc1'),
      ],
    );

    await _tickRow(tester, 'Stay in Paris');

    expect(find.text('Add to budget?'), findsNothing);
    expect(budgetApi.addCalls, isEmpty);
  });

  testWidgets(
      'unticking removes the linked AUTO expense and leaves a taken-over one',
      (tester) async {
    _useTallViewport(tester);
    const bookedTodo = BookingTodo(
        id: 'td-stay',
        kind: 'stay',
        todoKey: 'stay:paris',
        title: 'Stay in Paris',
        booked: true);
    const bookedStay = Accommodation(
        id: 'acc1', name: 'Hotel Lutetia', address: 'Paris', booked: true);
    final (_, budgetApi) = await _pump(
      tester,
      _trip(todos: const [bookedTodo], accommodations: const [bookedStay]),
      seedExpenses: const [
        // System-managed mirror: goes with the unbook.
        Expense(
            id: 'e-auto',
            category: 'lodging',
            label: 'Hotel Lutetia',
            amount: 150,
            auto: true,
            sourceKind: 'accommodation',
            sourceId: 'acc1'),
        // Manual entry, no link: never touched.
        Expense(id: 'e-manual', category: 'food', label: 'Dinner', amount: 40),
      ],
    );

    await _tickRow(tester, 'Stay in Paris'); // true -> false

    expect(find.text('Add to budget?'), findsNothing); // unbook never prompts
    expect(budgetApi.deletedIds, ['e-auto']);
    expect(budgetApi.expenses.map((e) => e.id), ['e-manual']);
  });

  testWidgets('unticking leaves a taken-over (auto=false) linked expense',
      (tester) async {
    _useTallViewport(tester);
    const bookedTodo = BookingTodo(
        id: 'td-stay',
        kind: 'stay',
        todoKey: 'stay:paris',
        title: 'Stay in Paris',
        booked: true);
    const bookedStay = Accommodation(
        id: 'acc1', name: 'Hotel Lutetia', address: 'Paris', booked: true);
    final (_, budgetApi) = await _pump(
      tester,
      _trip(todos: const [bookedTodo], accommodations: const [bookedStay]),
      seedExpenses: const [
        Expense(
            id: 'e-owned',
            category: 'lodging',
            label: 'Hotel Lutetia (edited)',
            amount: 175,
            auto: false,
            sourceKind: 'accommodation',
            sourceId: 'acc1'),
      ],
    );

    await _tickRow(tester, 'Stay in Paris'); // true -> false

    expect(budgetApi.deletedIds, isEmpty);
    expect(budgetApi.expenses.map((e) => e.id), ['e-owned']);
  });
}
