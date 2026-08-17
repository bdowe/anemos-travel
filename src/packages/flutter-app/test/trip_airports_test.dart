import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/airport.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/flights_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';
import 'package:travel_route_planner/widgets/trip_airports_sheet.dart';

import 'support/l10n_test_app.dart';

/// The trip page's control for THIS trip's departure/return airports
/// (specs/trip-endpoint-airports, wave 2).
///
/// Before it, the only affordance on a derived "EWR → Amsterdam" row was
/// "Add details…", which POSTs a segment — so a traveler correcting EWR to ALB
/// got a second row contradicting the first, and the airport never moved.
///
/// The app-bar overflow briefly carried a second entry into the same sheet,
/// covering a trip with no derived legs to hang the row link on. It has been
/// removed: the rows are the door.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  final List<(String?, String?)> saved = [];
  Object? failWith;

  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;

  @override
  Future<TripEndpointsResult> updateTripEndpoints(
    String tripId, {
    required String? originAirport,
    required String? returnAirport,
  }) async {
    saved.add((originAirport, returnAirport));
    if (failWith != null) throw failWith!;
    return const TripEndpointsResult(
      originAirport: 'ALB',
      returnAirport: 'ALB',
      legsRenamed: [
        RelabelledLeg(
            before: 'EWR → Amsterdam', after: 'ALB → Amsterdam', booked: true),
      ],
    );
  }
}

class _FakeFlightsApiService extends FlightsApiService {
  _FakeFlightsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Airport>> searchAirports(String query) async => const [
        Airport(
          iataCode: 'ALB',
          name: 'Albany International Airport',
          city: 'Albany',
          country: 'US',
          subType: 'airport',
        ),
      ];
}

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city, NL',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

BookingTodo _todo(String kind, String key, String title,
        {String? role, bool auto = true}) =>
    BookingTodo(
        id: key, kind: kind, todoKey: key, title: title, role: role, auto: auto);

/// A two-city trip whose first and last transport rows are the journey's ends,
/// labelled by the server with the roles it stores as identity.
Trip _trip() => Trip(
      id: 't1',
      title: 'Europe',
      startDate: '2026-08-24',
      endDate: '2026-08-28',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      originAirport: 'EWR',
      returnAirport: 'EWR',
      items: [
        _item(0, 'Rijksmuseum', 'Amsterdam', day: 1),
        _item(1, 'Colosseum', 'Rome', day: 3),
      ],
      bookingTodos: [
        _todo('transport', 'transport:ewr>>amsterdam', 'EWR → Amsterdam',
            role: 'home_outbound'),
        _todo('stay', 'stay:amsterdam', 'Stay in Amsterdam', role: 'stay'),
        _todo('transport', 'transport:amsterdam>>rome', 'Amsterdam → Rome',
            role: 'inter_city'),
        _todo('stay', 'stay:rome', 'Stay in Rome', role: 'stay'),
        _todo('transport', 'transport:rome>>ewr', 'Rome → EWR',
            role: 'home_return'),
      ],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpTrip(WidgetTester tester, _FakeTripsApiService trips) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(trips),
        flightsApiServiceProvider.overrideWithValue(_FakeFlightsApiService()),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the ⋮ of the row whose title is [title].
Future<void> _openRowMenu(WidgetTester tester, String title) async {
  final row = find.ancestor(
      of: find.text(title), matching: find.byType(BookingTodoRow));
  await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.more_vert)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('only the journey endpoints offer to change an airport',
      (tester) async {
    _useTallViewport(tester);
    await _pumpTrip(tester, _FakeTripsApiService(_trip()));

    await _openRowMenu(tester, 'EWR → Amsterdam');
    expect(find.text('Change departure airport…'), findsOneWidget);
    expect(find.text('Add details…'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // dismiss
    await tester.pumpAndSettle();

    // The leg home says "return", because it is the other end of the journey.
    await _openRowMenu(tester, 'Rome → EWR');
    expect(find.text('Change return airport…'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // An inter-city leg is titled from the itinerary's cities, which this does
    // not move — offering it there would promise something it can't do.
    await _openRowMenu(tester, 'Amsterdam → Rome');
    expect(find.text('Change departure airport…'), findsNothing);
    expect(find.text('Change return airport…'), findsNothing);
    expect(find.text('Add details…'), findsOneWidget);
  });

  testWidgets('changing the departure airport saves both ends together',
      (tester) async {
    _useTallViewport(tester);
    final trips = _FakeTripsApiService(_trip());
    await _pumpTrip(tester, trips);

    await _openRowMenu(tester, 'EWR → Amsterdam');
    await tester.tap(find.text('Change departure airport…'));
    await tester.pumpAndSettle();
    expect(find.byType(TripAirportsSheet), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Departs from'), 'Albany');
    await tester.pump(const Duration(milliseconds: 350)); // debounce
    await tester.pumpAndSettle();
    await tester.tap(find.text('Albany (ALB)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Both columns are written together: null never means "same as the other
    // direction", so the sheet cannot post a one-sided change.
    expect(trips.saved, [('ALB', 'ALB')]);
    expect(find.text('Saved. 1 leg renamed.'), findsOneWidget);
  });

  testWidgets('the airports live on the journey rows, not the app-bar menu',
      (tester) async {
    _useTallViewport(tester);
    await _pumpTrip(tester, _FakeTripsApiService(_trip()));

    // The overflow used to carry a "Trip airports…" entry for the trip with no
    // derived legs. It is gone: a duplicate door on a trip-wide menu is one
    // more thing between a traveler and the row that actually names the
    // airport, and the row is where somebody changing one looks first.
    await tester.tap(find.descendant(
        of: find.byType(AppBar), matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    expect(find.text('Trip airports…'), findsNothing);
    await tester.tapAt(const Offset(5, 5)); // dismiss
    await tester.pumpAndSettle();

    // …and the remaining door still reaches the same sheet.
    await _openRowMenu(tester, 'EWR → Amsterdam');
    await tester.tap(find.text('Change departure airport…'));
    await tester.pumpAndSettle();
    expect(find.byType(TripAirportsSheet), findsOneWidget);
  });

  testWidgets('Add details… on a derived leg cannot redefine its endpoints',
      (tester) async {
    _useTallViewport(tester);
    await _pumpTrip(tester, _FakeTripsApiService(_trip()));

    await _openRowMenu(tester, 'EWR → Amsterdam');
    await tester.tap(find.text('Add details…'));
    await tester.pumpAndSettle();

    // The endpoints are shown, not typed: this is where a traveler's correction
    // used to become a second, contradicting row.
    final from = tester.widget<TextField>(
        find.widgetWithText(TextField, 'From *').first);
    final to =
        tester.widget<TextField>(find.widgetWithText(TextField, 'To *').first);
    expect(from.readOnly, isTrue);
    expect(to.readOnly, isTrue);
    expect(find.text('Set by the trip.'), findsOneWidget);

    // …and it points at the control that really does change them.
    await tester.tap(find.text('Change airport'));
    await tester.pumpAndSettle();
    expect(find.byType(TripAirportsSheet), findsOneWidget);
  });

  group('TripAirportsSheet', () {
    Future<void> pumpSheet(WidgetTester tester,
        {String? origin, String? returnAirport, String? fallback}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            flightsApiServiceProvider
                .overrideWithValue(_FakeFlightsApiService()),
          ],
          child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: Scaffold(
              body: TripAirportsSheet(
                originAirport: origin,
                returnAirport: returnAirport,
                fallbackLabel: fallback,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an unresolved edit is refused, not silently dropped',
        (tester) async {
      await pumpSheet(tester, origin: 'EWR', returnAirport: 'EWR');
      await tester.enterText(
          find.widgetWithText(TextField, 'Departs from'), 'Albn');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // Still open, with the reason on the field. Saving it as "no airport"
      // would throw the edit away under a success message.
      expect(find.byType(TripAirportsSheet), findsOneWidget);
      expect(find.text('Pick an airport from the list.'), findsOneWidget);
    });

    testWidgets('a trip with no airport of its own names what it falls back to',
        (tester) async {
      await pumpSheet(tester, fallback: 'EWR');
      expect(find.text('Right now these legs use EWR.'), findsOneWidget);
      // Shown, never seeded: opening the sheet and pressing Save must not
      // promote a fallback into a fixed choice for this trip.
      final field = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Departs from').first);
      expect(field.controller?.text, isEmpty);
      // Nor is there anything to clear yet.
      expect(find.text('Use my home airport'), findsNothing);
    });

    testWidgets('the second field appears only when the ends differ',
        (tester) async {
      await pumpSheet(tester, origin: 'ALB', returnAirport: 'ALB');
      expect(find.widgetWithText(TextField, 'Returns into'), findsNothing);

      await tester.tap(find.text('Comes home into the same airport'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Returns into'), findsOneWidget);
    });

    testWidgets('asymmetric endpoints open with both fields showing',
        (tester) async {
      await pumpSheet(tester, origin: 'ALB', returnAirport: 'EWR');
      expect(find.widgetWithText(TextField, 'Returns into'), findsOneWidget);
    });
  });
}
