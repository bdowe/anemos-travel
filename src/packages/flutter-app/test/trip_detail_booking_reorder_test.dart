import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Sync fails (so the todos seeded on the trip survive, mirroring the screen's
/// swallow-on-error behavior); reorder calls are recorded and optionally fail.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  final List<List<String>> reorderCalls = [];
  final bool failReorder;
  _FakeBookingTodosApiService({this.failReorder = false})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');

  @override
  Future<void> reorderTodos(String tripId, List<String> todoIds) async {
    reorderCalls.add(todoIds);
    if (failReorder) throw Exception('server said no');
  }
}

BookingTodo _customTodo(String id, String title) => BookingTodo(
    id: id, kind: 'other', todoKey: 'custom:$id', title: title, auto: false);

Trip _tripWith(List<BookingTodo> todos) => Trip(
      id: 't1',
      title: 'Errands',
      startDate: '2026-06-10',
      endDate: '2026-06-13',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [],
      bookingTodos: todos,
    );

/// The itinerary renders lazily (slivers), so widgets below the default
/// 800x600 test viewport never get built. A tall viewport keeps the whole
/// page — including the trailing bookings section — built and findable.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<_FakeBookingTodosApiService> _pumpTrip(WidgetTester tester, Trip trip,
    {bool failReorder = false}) async {
  final fake = _FakeBookingTodosApiService(failReorder: failReorder);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  // Residual "Other bookings" cards render directly at the itinerary's tail.
  await tester.ensureVisible(find.text('Other bookings'));
  return fake;
}

/// Drags [title]'s handle vertically by [dy] within the residual list.
Future<void> _dragCard(WidgetTester tester, String title, double dy) async {
  final card = find.widgetWithText(BookingTodoCard, title);
  final handle = find.descendant(
      of: card, matching: find.byIcon(Icons.drag_indicator));
  final gesture = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 100));
  // Move in steps so the reorderable list registers the drag progression.
  for (var i = 0; i < 5; i++) {
    await gesture.moveBy(Offset(0, dy / 5));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

double _cardTop(WidgetTester tester, String title) =>
    tester.getTopLeft(find.widgetWithText(BookingTodoCard, title)).dy;

void main() {
  testWidgets('residual cards show a drag handle and reorder persists',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pumpTrip(
      tester,
      _tripWith([
        _customTodo('a', 'Museum tickets'),
        _customTodo('b', 'Train passes'),
        _customTodo('c', 'Dinner reservation'),
      ]),
    );

    expect(find.byType(BookingTodoCard), findsNWidgets(3));
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(3));
    expect(_cardTop(tester, 'Museum tickets'),
        lessThan(_cardTop(tester, 'Train passes')));

    // Drag the first card down past the second.
    final cardHeight = tester
        .getSize(find.widgetWithText(BookingTodoCard, 'Museum tickets'))
        .height;
    await _dragCard(tester, 'Museum tickets', cardHeight + 20);

    // The server got the full residual subset in its new order...
    expect(fake.reorderCalls, [
      ['b', 'a', 'c']
    ]);
    // ...and the optimistic UI reflects it.
    expect(_cardTop(tester, 'Train passes'),
        lessThan(_cardTop(tester, 'Museum tickets')));
    expect(_cardTop(tester, 'Museum tickets'),
        lessThan(_cardTop(tester, 'Dinner reservation')));
  });

  testWidgets('failed reorder reverts the order and shows a snackbar',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pumpTrip(
      tester,
      _tripWith([
        _customTodo('a', 'Museum tickets'),
        _customTodo('b', 'Train passes'),
      ]),
      failReorder: true,
    );

    final cardHeight = tester
        .getSize(find.widgetWithText(BookingTodoCard, 'Museum tickets'))
        .height;
    await _dragCard(tester, 'Museum tickets', cardHeight + 20);

    expect(fake.reorderCalls, [
      ['b', 'a']
    ]);
    // Rolled back to the original order, with an error surfaced.
    expect(_cardTop(tester, 'Museum tickets'),
        lessThan(_cardTop(tester, 'Train passes')));
    expect(find.textContaining('Could not reorder'), findsOneWidget);
  });

  testWidgets('a single residual card gets no drag handle',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    await _pumpTrip(tester, _tripWith([_customTodo('a', 'Museum tickets')]));

    expect(find.byType(BookingTodoCard), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
  });
}
