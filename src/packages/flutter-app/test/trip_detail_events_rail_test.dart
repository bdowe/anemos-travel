import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/event.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/events_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/utils/event_picks.dart';
import 'package:travel_route_planner/widgets/city_events_sheet.dart';
import 'package:travel_route_planner/widgets/event_card.dart';
import 'package:travel_route_planner/widgets/place_photo_card.dart';

import 'support/l10n_test_app.dart';

// How a city group surfaces its live events.
//
// The section is a poster RAIL, not a stack of full-width cards: fixed height
// regardless of how many events a city has, a header that counts everything
// found (not the cards shown), and a "See all" into the full list. The picks
// are day-spread, so a busy first night cannot hide the rest of the stay.
//
// The window the rail queries is the one the city header chip renders
// (visibleLegRanges). Querying anything else lets a section promising "while
// you're here" ask about dates the traveler was never shown — the bug that
// made a Sep 1–4 Berlin leg return five events, all on the checkout day.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');
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

Event _event(String date, String time, String name) => Event(
      id: '$date-$time',
      name: name,
      venue: 'Somewhere',
      category: 'Music',
      startDate: date,
      startTime: time,
      url: 'https://tickets.example.com/$date-$time',
      // Image.network fails in the test harness and falls through to the
      // card's errorBuilder, same as test/chat_panel_place_strip_test.dart.
      imageUrl: 'https://images.example.com/$date-$time.jpg',
    );

/// Berlin Sep 1–4 as the live API returns it: events on every day, most of
/// them bunched on the last one.
List<Event> _berlinEvents() => [
      _event('2026-09-01', '19:00', 'Swingin Hermlins'),
      _event('2026-09-01', '20:30', 'Baby Keem'),
      _event('2026-09-02', '19:30', 'Was Ihr wollt'),
      _event('2026-09-02', '20:00', 'Saying the Wrong Thing'),
      _event('2026-09-02', '20:15', 'YEBBA'),
      _event('2026-09-03', '18:30', 'Cirque du Soleil'),
      _event('2026-09-03', '20:00', 'Dance Gavin Dance'),
      _event('2026-09-04', '16:00', 'Brews Cruise'),
      _event('2026-09-04', '18:00', 'Lachkater Comedy'),
      _event('2026-09-04', '19:30', 'Romeo und Julia'),
      _event('2026-09-04', '19:35', 'Alex Spencer'),
      _event('2026-09-04', '20:00', 'Hallucinations'),
    ];

Trip _berlinTrip() => Trip(
      id: 't1',
      title: 'Poland & Germany',
      startDate: '2026-08-27',
      endDate: '2026-09-04',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        // Kraków runs day 1–6 of a trip starting Aug 27, i.e. Aug 27 – Sep 1.
        _item(0, 'Wawel', 'Kraków', day: 1),
        _item(1, 'Cloth Hall', 'Kraków', day: 6),
        // One Berlin item, day-tagged to the trip's last day — the shape that
        // collapses Berlin's RAW range to Sep 4 alone while the header chip
        // still renders the arrival-adjusted Sep 1 – Sep 4.
        _item(2, 'Brandenburger Tor', 'Berlin', day: 9),
      ],
      bookingTodos: const [
        BookingTodo(
            id: 'td-stay',
            kind: 'stay',
            todoKey: 'stay:berlin',
            title: 'Stay in Berlin',
            provider: 'airbnb'),
      ],
    );

/// A city visited twice, with dates, so both runs build a real EventsQuery.
Trip _revisitTrip() => Trip(
      id: 't2',
      title: 'Cyclades',
      startDate: '2026-09-01',
      endDate: '2026-09-06',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Oia', 'Fira', day: 1),
        _item(1, 'Portara', 'Naxos', day: 3),
        _item(2, 'Red Beach', 'Fira', day: 5),
      ],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester,
  Trip trip, {
  required List<Event> Function(EventsQuery) events,
  List<EventsQuery>? seen,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
        eventsByCityProvider.overrideWith((ref, query) async {
          seen?.add(query);
          return events(query);
        }),
      ],
      child: localizedTestApp(home: TripDetailScreen(tripId: trip.id)),
    ),
  );
  await tester.pumpAndSettle();
}

/// The rail's card list as DATA. The strip is a lazy horizontal ListView, so
/// asserting on built [PlacePhotoCard] widgets would silently depend on the
/// test viewport's width.
List<PlacePhotoCard> _railCards(WidgetTester tester) =>
    tester.widget<PlacePhotoStrip>(find.byType(PlacePhotoStrip)).cards;

void main() {
  testWidgets('the events section is one fixed-height rail, not a card wall',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _berlinTrip(),
        events: (q) => q.city == 'Berlin' ? _berlinEvents() : const []);

    expect(find.byType(PlacePhotoStrip), findsOneWidget);
    // No full-width event cards in the itinerary at all — those live in the
    // sheet now.
    expect(find.byType(EventCard), findsNothing);
    // Read the strip's card list, not the rendered cards: the rail is a lazy
    // horizontal ListView, so how many are BUILT depends on viewport width.
    expect(_railCards(tester).length, kEventRailCards);
  });

  testWidgets('the header counts every event found, not the cards shown',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _berlinTrip(),
        events: (q) => q.city == 'Berlin' ? _berlinEvents() : const []);

    expect(find.text("12 events while you're here"), findsOneWidget);
  });

  testWidgets('at the server cap the count says 30+, not 30', (tester) async {
    _useTallViewport(tester);
    final capped = [
      for (var i = 0; i < kEventsServerCap; i++)
        _event('2026-09-04', '${(i % 12) + 8}:00', 'Event $i'),
    ];
    await _pump(tester, _berlinTrip(),
        events: (q) => q.city == 'Berlin' ? capped : const []);

    expect(find.text("30+ events while you're here"), findsOneWidget);
    expect(find.text("30 events while you're here"), findsNothing);
  });

  testWidgets('the rail picks spread across the stay, not just day one',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _berlinTrip(),
        events: (q) => q.city == 'Berlin' ? _berlinEvents() : const []);

    // Two per day across all four days, chronologically. A plain take(8)
    // would have shown 2 from Sep 1, 3 from Sep 2, 2 from Sep 3 and 1 from
    // Sep 4 — the busy last day almost entirely hidden.
    expect(_railCards(tester).map((c) => c.data.title), [
      'Swingin Hermlins', 'Baby Keem', // Sep 1
      'Was Ihr wollt', 'Saying the Wrong Thing', // Sep 2
      'Cirque du Soleil', 'Dance Gavin Dance', // Sep 3
      'Brews Cruise', 'Lachkater Comedy', // Sep 4
    ]);
  });

  testWidgets('See all opens the full list; absent when nothing is hidden',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _berlinTrip(),
        events: (q) => q.city == 'Berlin' ? _berlinEvents() : const []);

    expect(find.text('See all'), findsOneWidget);
    await tester.tap(find.text('See all'));
    await tester.pumpAndSettle();

    expect(find.byType(CityEventsSheetBody), findsOneWidget);
    expect(find.text('Events in Berlin'), findsOneWidget);
    // Every event, including the ones the rail's shortlist left out.
    expect(find.byType(EventCard), findsNWidgets(12));
    // Including the ones the rail's shortlist left out.
    expect(find.text('YEBBA'), findsOneWidget);
    // Days are stated once as headers, not repeated on every card. Scoped to
    // the sheet: the itinerary behind it renders its own day headers.
    Finder inSheet(String text) => find.descendant(
        of: find.byType(CityEventsSheetBody), matching: find.text(text));
    expect(inSheet('Tue, Sep 1'), findsOneWidget);
    expect(inSheet('Fri, Sep 4'), findsOneWidget);
    // The cards under a day header show the clock time only.
    expect(inSheet('19:00'), findsOneWidget);
    expect(inSheet('Tue, Sep 1 · 19:00'), findsNothing);
  });

  testWidgets('no See all when the rail already shows everything',
      (tester) async {
    _useTallViewport(tester);
    final few = [
      _event('2026-09-02', '19:00', 'Only one'),
      _event('2026-09-03', '20:00', 'And another'),
    ];
    await _pump(tester, _berlinTrip(),
        events: (q) => q.city == 'Berlin' ? few : const []);

    expect(find.byType(PlacePhotoStrip), findsOneWidget);
    expect(find.text('See all'), findsNothing);
  });

  testWidgets('the rail queries the window the city header shows',
      (tester) async {
    _useTallViewport(tester);
    final seen = <EventsQuery>[];
    await _pump(tester, _berlinTrip(),
        events: (q) => q.city == 'Berlin' ? _berlinEvents() : const [],
        seen: seen);

    final berlin = seen.firstWhere((q) => q.city == 'Berlin');
    // Berlin's only item is day-tagged to Sep 4, so its RAW range is that one
    // day; the header chip renders the arrival-adjusted Sep 1 – Sep 4 and the
    // lookup must agree with it.
    expect(berlin.startDate, '2026-09-01');
    expect(berlin.endDate, '2026-09-04');
  });

  testWidgets('a revisited city looks up each visit on its own window',
      (tester) async {
    _useTallViewport(tester);
    final seen = <EventsQuery>[];
    await _pump(tester, _revisitTrip(),
        events: (_) => const <Event>[], seen: seen);

    final fira = seen.where((q) => q.city == 'Fira').toList();
    expect(fira.length, 2);
    // Two runs, two windows — not one label-keyed window used twice.
    expect(
      {for (final q in fira) '${q.startDate}..${q.endDate}'}.length,
      2,
      reason: 'both Fira visits queried the same window',
    );
  });

  testWidgets('empty and error stay silent for a non-Greek city',
      (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _berlinTrip(), events: (_) => const <Event>[]);

    expect(find.byType(PlacePhotoStrip), findsNothing);
    expect(find.byType(EventCard), findsNothing);
    expect(find.textContaining("while you're here"), findsNothing);
  });
}
