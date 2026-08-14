import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/up_next_trip_card.dart';

import 'support/l10n_test_app.dart';

/// Server-enriched list rows (item_count / booking_total / booking_booked /
/// shared): cards render booking-progress and Shared pills plus a places
/// count, and hide ALL of them when the fields are null (old server, stale
/// offline snapshot) — no local derivation, the server row is the one
/// derivation for list display.
class _FixedTripsApiService extends TripsApiService {
  /// Each listTrips() call serves the freshest queued response (the last one
  /// once exhausted), so a test can change what a refresh returns.
  final List<List<Trip>> responses;
  int listCalls = 0;

  _FixedTripsApiService(List<Trip> trips, {List<Trip>? then})
      : responses = [trips, if (then != null) then],
        super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async {
    final i = listCalls < responses.length ? listCalls : responses.length - 1;
    listCalls++;
    return responses[i];
  }

  @override
  Future<Trip> getTrip(String id) async =>
      responses.expand((r) => r).firstWhere((t) => t.id == id);
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Future<void> _pumpList(WidgetTester tester, List<Trip> trips,
    {_FixedTripsApiService? service}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(service ?? _FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripsListScreen()),
    ),
  );
}

Trip _enriched(String id, String title,
        {String? start,
        String? end,
        int? itemCount,
        int? bookingTotal,
        int? bookingBooked,
        bool? shared}) =>
    Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      itemCount: itemCount,
      bookingTotal: bookingTotal,
      bookingBooked: bookingBooked,
      shared: shared,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('enriched plain card shows booked progress, Shared, and places',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      // Soonest → hero, so the enriched assertions hit the plain card.
      _enriched('hero', 'Weekend Hop', start: _rel(5), end: _rel(6)),
      _enriched('t2', 'Big Summer Adventure',
          start: _rel(40),
          end: _rel(45),
          itemCount: 42,
          bookingTotal: 9,
          bookingBooked: 3,
          shared: true),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('3/9 booked'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);
    expect(find.text('42 places'), findsOneWidget);
  });

  testWidgets('null enrichment fields hide every chip (old-server guard)',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _enriched('hero', 'Weekend Hop', start: _rel(5), end: _rel(6)),
      _enriched('t2', 'Legacy Trip', start: _rel(40), end: _rel(45)),
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('booked'), findsNothing);
    expect(find.text('Shared'), findsNothing);
    expect(find.textContaining('place'), findsNothing);
  });

  testWidgets('zero booked still renders — 0/2 is state, not absence',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _enriched('hero', 'Weekend Hop', start: _rel(5), end: _rel(6)),
      _enriched('t2', 'Unbooked Trip',
          start: _rel(40), end: _rel(45), bookingTotal: 2, bookingBooked: 0),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('0/2 booked'), findsOneWidget);
  });

  testWidgets('the promoted hero keeps its booking-progress pill',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _enriched('hero', 'Lisbon Trip',
          start: _rel(10), end: _rel(13), bookingTotal: 4, bookingBooked: 1),
    ]);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
          of: find.byType(UpNextTripCard),
          matching: find.text('1/4 booked')),
      findsOneWidget,
    );
  });

  testWidgets('returning from the detail screen refreshes the counts',
      (WidgetTester tester) async {
    // The list mounts once (IndexedStack shell) and the detail screen edits
    // booked state, so the pop back is the list's refresh point — without
    // it the pill would show the pre-edit count until pull-to-refresh.
    Trip snapshot(int booked) => _enriched('hero', 'Lisbon Trip',
        start: _rel(10), end: _rel(13), bookingTotal: 4, bookingBooked: booked);
    final service =
        _FixedTripsApiService([snapshot(1)], then: [snapshot(3)]);

    await _pumpList(tester, const [], service: service);
    await tester.pumpAndSettle();
    expect(find.text('1/4 booked'), findsOneWidget);

    await tester.tap(find.byType(UpNextTripCard));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('3/4 booked'), findsOneWidget);
    expect(find.text('1/4 booked'), findsNothing);
  });
}
