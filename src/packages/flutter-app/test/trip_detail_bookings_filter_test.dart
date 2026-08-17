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
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';
import 'package:travel_route_planner/widgets/booking_filter_bar.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

import 'support/l10n_test_app.dart';

/// The Bookings view's filter row: the "Not booked yet" scope chip, the All
/// chip, and the scrolling destination strip whose chips carry their own
/// booked counts.
///
/// The load-bearing property is the one PR #455 paid for on the Trip Health
/// badge: **a count and the rows it summarizes must be the same answer**. So
/// the counting tests never assert a hard-coded number against a hard-coded
/// number — they select the chip and count the checkboxes that appear.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  // Mirrors the screen's swallow-on-error so the seeded todos survive.
  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');
}

class _FakeAccommodationsApiService extends AccommodationsApiService {
  _FakeAccommodationsApiService() : super(ApiClient(baseUrl: 'http://test'));
}

ItineraryItem _item(int pos, String name, String city, int day) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city, Europe',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip({
  required List<ItineraryItem> items,
  List<BookingTodo>? todos,
  List<Accommodation>? accommodations,
  List<TripSegment>? segments,
}) =>
    Trip(
      id: 't1',
      title: 'Europe',
      startDate: '2026-06-10',
      endDate: '2026-06-20',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: items,
      bookingTodos: todos,
      accommodations: accommodations,
      segments: segments,
    );

/// A trip through [cities], one item per city, one stay todo per city. The
/// [booked] set names the cities whose stay is already booked.
Trip _cityTrip(List<String> cities, {Set<String> booked = const {}}) => _trip(
      items: [
        for (final (i, c) in cities.indexed) _item(i, 'Sight in $c', c, i + 1),
      ],
      todos: [
        for (final c in cities)
          BookingTodo(
            id: 'td-${c.toLowerCase()}',
            kind: 'stay',
            todoKey: 'stay:${c.toLowerCase()}',
            title: 'Stay in $c',
            booked: booked.contains(c),
          ),
      ],
    );

void _useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Trip trip,
    {Locale? locale, double textScale = 1.0}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
        accommodationsApiServiceProvider
            .overrideWithValue(_FakeAccommodationsApiService()),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        supportedLocales: const [Locale('en'), Locale('es')],
        locale: locale,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openBookingsTab(WidgetTester tester,
    {String label = 'Bookings'}) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Finder _chip(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip));

/// Brings a chip into view (the strip scrolls) and taps it.
Future<void> _tapDestination(WidgetTester tester, String label) async {
  await tester.ensureVisible(_chip(label));
  await tester.pumpAndSettle();
  await tester.tap(_chip(label));
  await tester.pumpAndSettle();
}

/// The `· n/m` count riding a destination chip, parsed back out.
({int booked, int total}) _countOn(WidgetTester tester, String label) {
  final text = tester
      .widgetList<Text>(find.descendant(
          of: _chip(label), matching: find.byType(Text)))
      .map((t) => t.data ?? '')
      .firstWhere((d) => d.contains('/'),
          orElse: () => throw StateError('no count on chip "$label"'));
  final parts = text.replaceAll('·', '').trim().split('/');
  return (booked: int.parse(parts[0]), total: int.parse(parts[1]));
}

/// Every booking checkbox currently on screen, and how many are ticked — the
/// rows' own answer to the question the chip count claims to answer.
({int booked, int total}) _visibleRowCounts(WidgetTester tester) {
  final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
  return (
    booked: boxes.where((c) => c.value == true).length,
    total: boxes.length,
  );
}

void main() {
  testWidgets('the tab pill is the sum of the destination chips',
      (tester) async {
    _useViewport(tester, const Size(900, 3000));
    // A fixture where todos and entries genuinely differ: two stay todos
    // (one booked) plus a booked confirmed segment that matched no todo — a
    // third checkbox the old todo-count pill never saw ('1/2' vs the three
    // rows actually behind the tab).
    await _pump(
      tester,
      _trip(
        items: [
          _item(0, 'Louvre', 'Paris', 1),
          _item(1, 'Colosseum', 'Rome', 2),
        ],
        todos: const [
          BookingTodo(
              id: 'td-paris',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris',
              booked: true),
          BookingTodo(
              id: 'td-rome',
              kind: 'stay',
              todoKey: 'stay:rome',
              title: 'Stay in Rome'),
        ],
        segments: const [
          TripSegment(
              id: 'seg-x',
              mode: 'train',
              origin: 'Lyon',
              destination: 'Marseille',
              booked: true),
        ],
      ),
    );

    // The pill already carries the entries count before the tab is opened.
    expect(
        find.descendant(
            of: find.byType(StatusPill), matching: find.text('2/3')),
        findsOneWidget);
    expect(find.text('1/2'), findsNothing,
        reason: 'the todo-only count must not survive anywhere');

    await _openBookingsTab(tester);

    // The pill equals the fold of the chips — parsed from the same render.
    var booked = 0, total = 0;
    for (final label in const ['Paris', 'Rome', 'Other bookings']) {
      final c = _countOn(tester, label);
      booked += c.booked;
      total += c.total;
    }
    expect((booked: booked, total: total), (booked: 2, total: 3));

    // ...and both equal the checkboxes the tab actually reveals.
    expect(_visibleRowCounts(tester), (booked: 2, total: 3));
  });

  testWidgets('a chip count equals the rows that chip reveals', (tester) async {
    _useViewport(tester, const Size(900, 3000));
    await _pump(
      tester,
      _cityTrip(const ['Paris', 'Rome', 'Berlin'], booked: {'Rome'}),
    );
    await _openBookingsTab(tester);

    for (final city in const ['Paris', 'Rome', 'Berlin']) {
      final claimed = _countOn(tester, city);
      await _tapDestination(tester, city);
      final rendered = _visibleRowCounts(tester);
      expect(rendered.total, claimed.total,
          reason: '$city chip claims ${claimed.total} bookings');
      expect(rendered.booked, claimed.booked,
          reason: '$city chip claims ${claimed.booked} booked');
      await _tapDestination(tester, 'All');
    }
  });

  testWidgets('a revisited city gets one chip whose count sums both runs',
      (tester) async {
    _useViewport(tester, const Size(900, 3000));
    // Paris → Rome → Paris: two Paris runs, ONE Paris chip.
    await _pump(
      tester,
      _trip(
        items: [
          _item(0, 'Louvre', 'Paris', 1),
          _item(1, 'Colosseum', 'Rome', 2),
          _item(2, 'Orsay', 'Paris', 3),
        ],
        todos: const [
          BookingTodo(
              id: 'td-p1',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris'),
          BookingTodo(
              id: 'td-r',
              kind: 'stay',
              todoKey: 'stay:rome',
              title: 'Stay in Rome'),
        ],
      ),
    );
    await _openBookingsTab(tester);

    expect(_chip('Paris'), findsOneWidget);
    final claimed = _countOn(tester, 'Paris');
    await _tapDestination(tester, 'Paris');
    expect(_visibleRowCounts(tester).total, claimed.total);
  });

  testWidgets('the Other chip counts the residuals, and only those',
      (tester) async {
    _useViewport(tester, const Size(900, 3000));
    await _pump(
      tester,
      _trip(
        items: [
          _item(0, 'Louvre', 'Paris', 1),
          _item(1, 'Colosseum', 'Rome', 2),
        ],
        todos: const [
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
        ],
      ),
    );
    await _openBookingsTab(tester);

    final claimed = _countOn(tester, 'Other bookings');
    expect(claimed.total, 1);
    await _tapDestination(tester, 'Other bookings');
    expect(
        find.widgetWithText(BookingTodoCard, 'Museum tickets'), findsOneWidget);
    expect(_visibleRowCounts(tester).total, claimed.total);
  });

  testWidgets('a confirmed record with no todo still counts as one booking',
      (tester) async {
    _useViewport(tester, const Size(900, 3000));
    await _pump(
      tester,
      _trip(
        items: [_item(0, 'Louvre', 'Paris', 1)],
        todos: const [
          BookingTodo(
              id: 'td-paris',
              kind: 'stay',
              todoKey: 'stay:paris',
              title: 'Stay in Paris'),
        ],
        // Matches no leg — lands in the residual bucket as a detail row.
        segments: const [
          TripSegment(
              id: 'seg-x',
              mode: 'train',
              origin: 'Lyon',
              destination: 'Marseille',
              booked: true),
        ],
      ),
    );
    await _openBookingsTab(tester);

    // One entry, already booked: the row is a BookingDetailRow with no todo.
    expect(_countOn(tester, 'Other bookings'), (booked: 1, total: 1));
    await _tapDestination(tester, 'Other bookings');
    expect(find.byType(BookingDetailRow), findsOneWidget);
  });

  testWidgets('the chosen destination survives a "Not booked yet" toggle',
      (tester) async {
    _useViewport(tester, const Size(900, 3000));
    await _pump(
      tester,
      _cityTrip(const ['Paris', 'Rome'], booked: {'Paris'}),
    );
    await _openBookingsTab(tester);

    await _tapDestination(tester, 'Rome');
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Not booked yet'));
    await tester.pumpAndSettle();

    // Still on Rome — the scope answered "what", not "where".
    final rome = tester.widget<ChoiceChip>(_chip('Rome'));
    expect(rome.selected, isTrue);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Paris'), findsNothing);
  });

  testWidgets(
      'a fully booked destination says so without claiming the trip is done',
      (tester) async {
    _useViewport(tester, const Size(900, 3000));
    await _pump(
      tester,
      _cityTrip(const ['Paris', 'Rome'], booked: {'Paris'}),
    );
    await _openBookingsTab(tester);
    await _tapDestination(tester, 'Paris');
    await tester.tap(find.widgetWithText(FilterChip, 'Not booked yet'));
    await tester.pumpAndSettle();

    // Paris is booked, Rome is not: the trip-wide celebration would be a lie.
    expect(find.text('Nothing left to book here.'), findsOneWidget);
    expect(find.text("Everything's booked"), findsNothing);

    // Clearing to All reveals what is genuinely left.
    await _tapDestination(tester, 'All');
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Rome'), findsOneWidget);
  });

  testWidgets('one destination and no residuals renders no strip at all',
      (tester) async {
    _useViewport(tester, const Size(900, 3000));
    await _pump(tester, _cityTrip(const ['Paris']));
    await _openBookingsTab(tester);

    // The scope chip stays — it still has something to say.
    expect(find.widgetWithText(FilterChip, 'Not booked yet'), findsOneWidget);
    // A one-city filter would show exactly what All shows.
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('the selected chip is revealed when it starts past the fold',
      (tester) async {
    // Narrow body, ten cities: the strip genuinely scrolls.
    _useViewport(tester, const Size(420, 2400));
    await _pump(
      tester,
      _cityTrip(const [
        'Paris',
        'Rome',
        'Berlin',
        'Prague',
        'Vienna',
        'Madrid',
        'Lisbon',
        'Athens',
        'Oslo',
        'Dublin',
      ]),
    );
    await _openBookingsTab(tester);

    await _tapDestination(tester, 'Dublin');

    // The strip scrolled the last chip into its OWN viewport rather than
    // leaving the selection somewhere off-screen.
    final strip = tester.getRect(find.descendant(
        of: find.byType(BookingFilterBar),
        matching: find.byType(Scrollable)));
    final chip = tester.getRect(_chip('Dublin'));
    expect(chip.left, greaterThanOrEqualTo(strip.left - 1));
    expect(chip.right, lessThanOrEqualTo(strip.right + 1));

    // The way back never scrolls away with it.
    expect(_chip('All'), findsOneWidget);
    expect(tester.getRect(_chip('All')).right, lessThanOrEqualTo(strip.left));
  });

  testWidgets('the filter row survives a narrow Spanish viewport at 1.3x',
      (tester) async {
    _useViewport(tester, const Size(320, 2400));
    await _pump(
      tester,
      _cityTrip(const ['Paris', 'Rome', 'Berlin']),
      locale: const Locale('es'),
      textScale: 1.3,
    );
    await _openBookingsTab(tester, label: 'Reservas');

    // A RenderFlex overflow throws, so this assert is not vacuous.
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(FilterChip, 'Sin reservar'), findsOneWidget);
    expect(_chip('Todas'), findsOneWidget);
  });
}
