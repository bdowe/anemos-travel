import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/event.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/events_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

// Alignment contracts for the itinerary's booking surface.
//
// Leading edge: every BookingTodoRow reserves the same fixed leading slot
// (kBookingRowLeadingSlot), so titles share one x whether the row leads with
// the bare kind icon (stays, menu-suppressed transport rows — same code
// branch) or with the wider icon+caret mode menu. BookingDetailRow and the
// section headers align to the same grid.
//
// Trailing edge: the open button renders its open_in_new glyph after the
// label (iconAlignment.end), so with the fixed-width kebab + checkbox
// packing the cluster right, every row's glyph lands on one column despite
// varying label widths ("Open in Airbnb" vs "Find flights").

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Sync fails (mirroring the screen's swallow-on-error), so the todos seeded
/// on the trip payload survive verbatim. A failed sync does NOT flip the
/// screen offline — only a failed trip fetch does — so the mode menu stays
/// live on transport rows.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');
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

const _confirmedStay = Accommodation(
  id: 'acc1',
  name: 'Hotel Lutetia',
  address: 'Paris',
  provider: 'Booking.com',
  checkIn: '2026-06-10',
  checkOut: '2026-06-12',
);

Trip _twoCityTrip() => Trip(
      id: 't1',
      title: 'Europe',
      startDate: '2026-06-10',
      endDate: '2026-06-13',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', 'Paris, France', 'Paris', day: 1),
        _item(1, 'Colosseum', 'Rome, Italy', 'Rome', day: 3),
      ],
      bookingTodos: const [
        BookingTodo(
            id: 'td-stay',
            kind: 'stay',
            todoKey: 'stay:paris',
            title: 'Stay in Paris',
            provider: 'airbnb'),
        // No confirmed segment matches this leg, so it carries the mode menu.
        BookingTodo(
            id: 'td-leg',
            kind: 'transport',
            todoKey: 'transport:paris>>rome',
            title: 'Paris → Rome'),
      ],
      accommodations: const [_confirmedStay],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
        // One event for Paris so its group renders the events header; empty
        // for Rome (the non-Greek fallback renders nothing).
        eventsByCityProvider.overrideWith((ref, query) async =>
            query.city == 'Paris'
                ? const [
                    Event(
                        id: 'e1',
                        name: 'Jazz night',
                        venue: 'Le Duc',
                        startDate: '2026-06-10')
                  ]
                : const <Event>[]),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: trip.id)),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inRow(String title, Finder inner) => find.descendant(
    of: find.widgetWithText(BookingTodoRow, title), matching: inner);

void main() {
  testWidgets(
      'todo titles, detail rows, and section headers share one leading grid',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _twoCityTrip());

    double dx(Finder f) => tester.getTopLeft(f).dx;

    // Groups default EXPANDED, so both cities' surfaces are measured in one
    // rendered pass (same gutter throughout).

    // The stay row leads with the bare kind icon (the same branch
    // menu-suppressed transport rows take, so it stands in for both).
    expect(_inRow('Stay in Paris', find.byIcon(Icons.arrow_drop_down)),
        findsNothing);
    final stayTitleDx = dx(find.text('Stay in Paris'));

    // The matched confirmed stay's detail row: its icon sits under the todo
    // titles.
    expect(
        dx(find.descendant(
            of: find.widgetWithText(BookingDetailRow, 'Hotel Lutetia'),
            matching: find.byIcon(Icons.hotel_outlined))),
        moreOrLessEquals(stayTitleDx, epsilon: 0.1));

    // The events rail's header icon (16px — the rail card below carries its
    // own 32px fallback copy) lines up with the rows' kind icons.
    final headerIcon = find.byWidgetPredicate(
        (w) => w is Icon && w.icon == Icons.local_activity && w.size == 16);
    expect(headerIcon, findsOneWidget);
    expect(dx(headerIcon),
        moreOrLessEquals(
            dx(_inRow('Stay in Paris', find.byIcon(Icons.hotel))),
            epsilon: 0.1));

    // Sanity: the leg row carries the icon+caret mode menu...
    expect(_inRow('Paris → Rome', find.byIcon(Icons.arrow_drop_down)),
        findsOneWidget);
    // ...and its title still starts at the same x as the stay title.
    expect(dx(find.text('Paris → Rome')),
        moreOrLessEquals(stayTitleDx, epsilon: 0.1));
  });

  testWidgets('open buttons share one trailing column', (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _twoCityTrip());

    double dx(Finder f) => tester.getTopLeft(f).dx;

    // The _inRow scoping is load-bearing: the Paris group also renders an
    // events rail whose cards carry their own bare open_in_new, and the
    // matched stay's BookingDetailRow carries trailing IconButtons.
    // Differing label widths are what make the dx equality meaningful.
    expect(_inRow('Stay in Paris', find.text('Open in Airbnb')),
        findsOneWidget);
    final iconDx =
        dx(_inRow('Stay in Paris', find.byIcon(Icons.open_in_new)));

    expect(_inRow('Paris → Rome', find.text('Find flights')), findsOneWidget);
    expect(dx(_inRow('Paris → Rome', find.byIcon(Icons.open_in_new))),
        moreOrLessEquals(iconDx, epsilon: 0.1));
  });
}
