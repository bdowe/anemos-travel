import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path (and its booking-todo derivation).
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Swallows the derived-payload sync like the offline test env.
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
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Future<void> _pump(WidgetTester tester, Trip trip, {Locale? locale}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
      ],
      child: localizedTestApp(
        home: TripDetailScreen(tripId: 't1'),
        locale: locale,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Prague Aug 24 – Aug 27 (3 nights), Kraków Aug 27 – Sep 1 (5 nights) —
/// the canonical example the feature was asked for.
Trip _pragueKrakowTrip() => Trip(
      id: 't1',
      title: 'Big Summer',
      status: 'planned',
      startDate: '2026-08-24',
      endDate: '2026-09-01',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Prague', 'Prague', day: 4),
        _item(1, 'Kraków', 'Kraków', day: 9),
      ],
    );

void main() {
  testWidgets('city headers carry a night count next to the date range',
      (WidgetTester tester) async {
    await _pump(tester, _pragueKrakowTrip());

    expect(find.text('Aug 24 – Aug 27 · 3 nights'), findsOneWidget);
    expect(find.text('Aug 27 – Sep 1 · 5 nights'), findsOneWidget);
  });

  testWidgets('a squeezed zero-night leg keeps its bare single-date chip',
      (WidgetTester tester) async {
    // Quito is squeezed onto its Sep 6 arrival (see
    // trip_detail_squeezed_leg_test.dart) — no "0 nights" noise on it, while
    // the following Galápagos leg still gets its counter.
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Squeeze',
        status: 'planned',
        startDate: '2026-09-01',
        endDate: '2026-09-07',
        createdAt: '2026-08-01',
        updatedAt: '2026-08-01',
        items: [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 5),
          _item(3, 'Mitad del Mundo', 'Galápagos', day: 6),
          _item(4, 'Tortuga Bay', 'Galápagos', day: 7),
        ],
      ),
    );

    expect(find.text('Sep 6'), findsWidgets);
    expect(find.textContaining('0 nights'), findsNothing);
    expect(find.text('Sep 6 – Sep 7 · 1 night'), findsWidgets);
  });

  testWidgets('night counts pluralize in Spanish',
      (WidgetTester tester) async {
    // Only the nights half is pinned: the date half comes from
    // DateFormat.MMMd(), which reads Intl.defaultLocale (English in the
    // test env) rather than the widget locale.
    await _pump(tester, _pragueKrakowTrip(), locale: const Locale('es'));

    expect(find.textContaining('3 noches'), findsOneWidget);
    expect(find.textContaining('5 noches'), findsOneWidget);
  });

  testWidgets('date chips sit flush right with aligned chevrons',
      (WidgetTester tester) async {
    // Regression: wrapping the chip Text in Flexible gave the header Row two
    // flex children, so the label's Expanded only claimed half the free
    // space and the chip+chevron cluster drifted left by a per-row amount.
    // The chevron must end exactly where its Row ends, on every row.
    await _pump(tester, _pragueKrakowTrip());

    double chevronRightIn(String chipText) {
      final row = find
          .ancestor(of: find.text(chipText), matching: find.byType(Row))
          .first;
      final chevron = find.descendant(
          of: row, matching: find.byIcon(Icons.chevron_right));
      expect(chevron, findsOneWidget);
      expect(
        tester.getTopRight(chevron).dx,
        moreOrLessEquals(tester.getTopRight(row).dx, epsilon: 0.1),
        reason: 'chevron of "$chipText" must be flush with its row end',
      );
      return tester.getTopRight(chevron).dx;
    }

    final prague = chevronRightIn('Aug 24 – Aug 27 · 3 nights');
    final krakow = chevronRightIn('Aug 27 – Sep 1 · 5 nights');
    expect(prague, moreOrLessEquals(krakow, epsilon: 0.1),
        reason: 'chevrons must align across rows');
  });

  testWidgets('phone width: header row never overflows and stays flush right',
      (WidgetTester tester) async {
    // The test font renders every glyph as a full-size square, so the chip
    // here measures far wider than any real font — the harshest squeeze the
    // row can see. The ConstrainedBox cap must ellipsize the chip (never
    // overflow), and the chevron must stay flush with the row end.
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _pragueKrakowTrip());

    final row = find
        .ancestor(
            of: find.text('Aug 24 – Aug 27 · 3 nights'),
            matching: find.byType(Row))
        .first;
    final chevron = find.descendant(
        of: row, matching: find.byIcon(Icons.chevron_right));
    expect(
      tester.getTopRight(chevron).dx,
      moreOrLessEquals(tester.getTopRight(row).dx, epsilon: 0.1),
      reason: 'chevron must stay flush with the row end at phone width',
    );
  });

  // The only tests that pin the separator and order — if the format ever
  // changes, the ARB lines and these literals are the whole diff.
  test('message-level plural forms in en and es', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    expect(en.tripLegDatesWithNights('R', 1), 'R · 1 night');
    expect(en.tripLegDatesWithNights('R', 3), 'R · 3 nights');

    final es = await AppLocalizations.delegate.load(const Locale('es'));
    expect(es.tripLegDatesWithNights('R', 1), 'R · 1 noche');
    expect(es.tripLegDatesWithNights('R', 5), 'R · 5 noches');
  });
}
