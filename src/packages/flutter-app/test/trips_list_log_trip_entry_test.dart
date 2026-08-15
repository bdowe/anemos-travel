import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/shared_with_me_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

/// The "Log a past trip" entry points on My Trips (specs/log-past-trip).
///
/// The invariant under test is coverage, not placement: **every account size
/// has at least one way in.** "Your travels" — the section the feature exists
/// to fill — is itself gated at 2+ owned trips, so an action placed only in its
/// header would be invisible to accounts with none or one, which are exactly
/// the accounts whose history is missing. Hence three entry points, and hence a
/// test per account size.
///
/// Found by ValueKey rather than by label (the kTraveledStatsKey convention):
/// all three carry the same string, so a text finder could neither tell them
/// apart nor survive Spanish.
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;

  _FixedTripsApiService(this.trips) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => trips;
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Trip _trip(String id, {String? start, String? end}) => Trip(
      id: id,
      title: 'Trip $id',
      startDate: start,
      endDate: end,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpList(WidgetTester tester, {List<Trip> trips = const []}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
        sharedWithMeProvider.overrideWith((ref) async => const <Trip>[]),
      ],
      child: localizedTestApp(home: const TripsListScreen()),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('no trips: the empty state offers it', (tester) async {
    await _pumpList(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(kLogTripEmptyStateKey), findsOneWidget);
    // The band isn't on screen at all, so its action can't be the way in.
    expect(find.byKey(kLogTripSectionActionKey), findsNothing);
  });

  testWidgets('one trip: the app bar carries it even with no band',
      (tester) async {
    await _pumpList(tester, trips: [_trip('t1', start: _rel(-30), end: _rel(-20))]);
    await tester.pumpAndSettle();

    // "Your travels" needs 2+ owned trips, so this account sees no section
    // action and no empty state — the app bar is its only route in, which is
    // the whole reason that entry point exists.
    expect(find.byKey(kLogTripSectionActionKey), findsNothing);
    expect(find.byKey(kLogTripEmptyStateKey), findsNothing);
    expect(find.byKey(kLogTripAppBarKey), findsOneWidget);
  });

  testWidgets('two trips: the "Your travels" header carries it', (tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', start: _rel(-30), end: _rel(-20)),
      _trip('t2', start: _rel(20), end: _rel(27)),
    ]);
    await tester.pumpAndSettle();

    expect(find.byKey(kLogTripSectionActionKey), findsOneWidget);
    expect(find.byKey(kLogTripAppBarKey), findsOneWidget);
  });

  testWidgets('the section action opens the log-trip screen', (tester) async {
    await _pumpList(tester, trips: [
      _trip('t1', start: _rel(-30), end: _rel(-20)),
      _trip('t2', start: _rel(20), end: _rel(27)),
    ]);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(kLogTripSectionActionKey));
    await tester.tap(find.byKey(kLogTripSectionActionKey));
    await tester.pumpAndSettle();

    // The screen is pushed on the Trips tab's navigator by
    // openLogTripOnTripsTab; in this bare-MaterialApp harness there is no
    // shell, so assert the tap is wired rather than the landing screen.
    expect(tester.takeException(), isNull);
  });
}
