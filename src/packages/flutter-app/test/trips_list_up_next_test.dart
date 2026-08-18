import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/live_trip_card.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';
import 'package:travel_route_planner/widgets/up_next_trip_card.dart';

import 'support/l10n_test_app.dart';

/// The "Up next" hero on the trips list: the soonest dated upcoming trip
/// promoted above the plain cards, REPLACING its own card (unlike the live
/// spotlight), suppressed entirely while a live trip exists, and wearing the
/// cached route map as a band on a cache hit (cache-only, the TripMapBand
/// contract — map assertions are structural, tile HTTP 400s are tolerated).
///
/// The hero also carries the insight facts the plain card can't
/// (specs/trips-page-insights): packing progress, stays, budget, the summary
/// blurb, and the booking-urgency nudge inside its 14-day window.
///
/// Dates are relative to DateTime.now() so the countdown is deterministic.
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;

  _FixedTripsApiService(this.trips) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => trips;

  @override
  Future<Trip> getTrip(String id) async =>
      trips.firstWhere((t) => t.id == id);
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Trip _trip(String id, String title,
        {String? start,
        String? end,
        List<String>? cities,
        String? summary,
        int? stayTotal,
        int? packingTotal,
        int? packingDone,
        double? budgetTarget,
        double? budgetSpent,
        String? budgetCurrency,
        String? nextTransportDepart}) =>
    Trip(
      id: id,
      title: title,
      summary: summary,
      startDate: start,
      endDate: end,
      cities: cities,
      stayTotal: stayTotal,
      packingTotal: packingTotal,
      packingDone: packingDone,
      budgetTarget: budgetTarget,
      budgetSpent: budgetSpent,
      budgetCurrency: budgetCurrency,
      nextTransportDepart: nextTransportDepart,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

/// A cached detail of [id] with two geocoded items — enough for the band's
/// mappable gate. Written in TripCache's entry format for user u1; seeding
/// raw prefs keys, never writeTrip mid-test (deferred-write queue hazard).
MapEntry<String, Object> _cachedTripEntry(String id) => MapEntry(
      'trip_cache.u1.trip.$id',
      jsonEncode({
        'saved_at': '2026-08-01T10:00:00.000',
        'trip': Trip(
          id: id,
          title: 'Lisbon Trip',
          startDate: _rel(10),
          endDate: _rel(13),
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: const [
            ItineraryItem(
              id: 'i0',
              position: 0,
              name: 'Alfama',
              city: 'Lisbon',
              latitude: 38.7139,
              longitude: -9.1334,
              category: 'attraction',
            ),
            ItineraryItem(
              id: 'i1',
              position: 1,
              name: 'Alhambra',
              city: 'Granada',
              latitude: 37.1761,
              longitude: -3.5881,
              category: 'attraction',
            ),
          ],
        ).toJson(),
      }),
    );

Future<void> _pumpList(
  WidgetTester tester,
  _FixedTripsApiService service,
) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(service),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripsListScreen()),
    ),
  );
}

/// Scopes a finder to the hero, so a plain card below can never satisfy an
/// assertion about the promoted trip.
Finder _inHero(Finder matching) =>
    find.descendant(of: find.byType(UpNextTripCard), matching: matching);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the soonest dated trip promotes to the hero and its plain '
      'card disappears (dedupe)', (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('later', 'Rome Trip', start: _rel(30), end: _rel(33)),
      _trip('up1', 'Lisbon Trip', start: _rel(10), end: _rel(13)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(UpNextTripCard), findsOneWidget);
    expect(find.text('Starts in 10 days'), findsOneWidget);
    // Hero replaces the card: the promoted title renders exactly once, the
    // non-promoted trip keeps its plain card.
    expect(find.text('Lisbon Trip'), findsOneWidget);
    expect(find.text('Rome Trip'), findsOneWidget);
  });

  testWidgets('a live trip suppresses the hero — one promoted object',
      (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('live', 'Athens Trip', start: _rel(-1), end: _rel(1)),
      _trip('up1', 'Lisbon Trip', start: _rel(10), end: _rel(13)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(LiveTripCard), findsOneWidget);
    expect(find.byType(UpNextTripCard), findsNothing);
    // Not promoted, so the future trip keeps its plain card.
    expect(find.text('Lisbon Trip'), findsOneWidget);
    // And the promoted one loses its own — whichever hero holds the slot,
    // it replaces the card (this was 2 before the 2026-08-15 amendment).
    expect(find.text('Athens Trip'), findsOneWidget);
  });

  testWidgets('undated-only lists get no hero', (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('draft', 'Someday Trip'),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(UpNextTripCard), findsNothing);
    expect(find.text('Someday Trip'), findsOneWidget);
  });

  testWidgets('tapping the hero opens the trip detail screen',
      (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip', start: _rel(10), end: _rel(13)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(UpNextTripCard));
    await tester.pumpAndSettle();

    expect(find.byType(TripDetailScreen), findsOneWidget);
  });

  testWidgets('a cached mappable trip mounts the map band inside the hero',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(
        Map.fromEntries([_cachedTripEntry('up1')]));
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip', start: _rel(10), end: _rel(13)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
          of: find.byType(UpNextTripCard), matching: find.byType(TripMap)),
      findsOneWidget,
    );
  });

  testWidgets('a cache miss keeps the hero band-less (cache-only contract)',
      (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip', start: _rel(10), end: _rel(13)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(UpNextTripCard), findsOneWidget);
    expect(find.byType(TripMap), findsNothing);
  });

  testWidgets('the hero carries packing, stays and the summary blurb',
      (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip',
          start: _rel(10),
          end: _rel(13),
          summary: 'Four days of miradouros, pastéis and fado.',
          stayTotal: 2,
          packingTotal: 20,
          packingDone: 12),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(_inHero(find.text('12/20 packed')), findsOneWidget);
    expect(_inHero(find.text('2 stays')), findsOneWidget);
    expect(
      _inHero(find.text('Four days of miradouros, pastéis and fado.')),
      findsOneWidget,
    );
  });

  testWidgets('the budget pill reads spent of target', (tester) async {
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip',
          start: _rel(10),
          end: _rel(13),
          budgetTarget: 800,
          budgetSpent: 540,
          budgetCurrency: 'EUR'),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(_inHero(find.text('€540 of €800')), findsOneWidget);
  });

  testWidgets('no target set — the pill reports the spend alone',
      (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip',
          start: _rel(10),
          end: _rel(13),
          budgetSpent: 540,
          budgetCurrency: 'EUR'),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(_inHero(find.text('€540 spent')), findsOneWidget);
    expect(find.textContaining(' of '), findsNothing);
  });

  testWidgets('an unbooked leg inside the window raises the nudge',
      (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip',
          start: _rel(10), end: _rel(13), nextTransportDepart: _rel(5)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    // The date itself is intl-formatted for the active locale, so the finder
    // matches the stable half of the sentence.
    expect(_inHero(find.textContaining('Book transport')), findsOneWidget);
  });

  testWidgets('a departure past the window raises no nudge',
      (WidgetTester tester) async {
    // 20 days out — beyond kBookingNudgeWindowDays, so the leg is not yet
    // urgent and the hero keeps one attention object at most.
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip',
          start: _rel(25), end: _rel(30), nextTransportDepart: _rel(20)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(UpNextTripCard), findsOneWidget);
    expect(find.textContaining('Book transport'), findsNothing);
  });

  testWidgets('a null departure (old server, or nothing unbooked) never nudges',
      (WidgetTester tester) async {
    final service = _FixedTripsApiService([
      _trip('up1', 'Lisbon Trip', start: _rel(3), end: _rel(6)),
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(UpNextTripCard), findsOneWidget);
    expect(find.textContaining('Book transport'), findsNothing);
  });
}
