import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/offline_banner.dart';
import 'package:travel_route_planner/l10n/l10n.dart';

import 'support/l10n_test_app.dart';

/// getTrip answers from a queue: a Trip resolves, anything else throws it.
class _QueuedTripsApiService extends TripsApiService {
  final List<Object> responses;
  int calls = 0;

  _QueuedTripsApiService(this.responses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) {
    final next =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (next is Trip) return Future.value(next);
    return Future.error(next);
  }
}

Trip _trip(String title) => Trip(
      id: 't1',
      title: title,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        // Zero coords so the screen skips the map widget in the test env.
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Acropolis',
          address: 'Athens, Greece',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
        ),
      ],
    );

/// FilledButton.tonalIcon / TextButton.icon build private subclasses, so
/// byType-based finders miss them; match by subtype around the label instead.
T _labeledButton<T extends ButtonStyleButton>(
        WidgetTester tester, String label) =>
    tester.widget<T>(find.ancestor(
      of: find.text(label),
      matching: find.bySubtype<T>(),
    ));

/// Crosses the RefreshIndicator's arm threshold to fire a quiet _load.
Future<void> _triggerRefresh(WidgetTester tester) async {
  await tester.fling(
      find.byType(CustomScrollView), const Offset(0, 400), 1000);
  await tester.pump(); // start the indicator
  await tester.pump(const Duration(seconds: 1)); // cross the arm threshold
}

Future<void> _pumpDetail(
    WidgetTester tester, _QueuedTripsApiService service, TripCache cache) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(service),
        tripCacheProvider.overrideWithValue(cache),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('relativeTime', () {
    test('formats coarse staleness labels', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final now = DateTime(2026, 7, 6, 12, 0);
      DateTime ago(Duration d) => now.subtract(d);
      expect(relativeTime(l10n, ago(const Duration(seconds: 20)), now: now),
          'just now');
      expect(relativeTime(l10n, ago(const Duration(minutes: 5)), now: now),
          '5 minutes ago');
      expect(relativeTime(l10n, ago(const Duration(hours: 1)), now: now),
          '1 hour ago');
      expect(relativeTime(l10n, ago(const Duration(days: 2)), now: now),
          '2 days ago');
    });

    // The 1-vs-N branches are ICU plurals now, so Spanish gets its own forms
    // rather than an English sentence with a translated noun.
    test('pluralizes in Spanish', () async {
      final es = await AppLocalizations.delegate.load(const Locale('es'));
      final now = DateTime(2026, 7, 6, 12, 0);
      DateTime ago(Duration d) => now.subtract(d);
      expect(relativeTime(es, ago(const Duration(hours: 1)), now: now),
          isNot(contains('hour')));
      expect(relativeTime(es, ago(const Duration(days: 2)), now: now),
          isNot(contains('days')));
    });
  });

  testWidgets(
      'network failure serves the cached trip read-only with an offline banner',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    await cache.writeTrip(_trip('Athens Trip'));
    final service =
        _QueuedTripsApiService([http.ClientException('connection refused')]);

    await _pumpDetail(tester, service, cache);
    await tester.pumpAndSettle();

    // The saved copy renders, clearly marked stale.
    expect(find.text('Acropolis'), findsOneWidget);
    expect(find.textContaining('Offline — showing saved copy from'),
        findsOneWidget);
    expect(find.text('Could not load this trip'), findsNothing);

    // Mutation affordances are disabled or hidden.
    final refine = _labeledButton<FilledButton>(tester, 'Refine with AI');
    expect(refine.onPressed, isNull, reason: 'chat/refine needs the network');
    final addPlace = _labeledButton<TextButton>(tester, 'Add place');
    expect(addPlace.onPressed, isNull);
    final rename = tester.widget<IconButton>(find.ancestor(
      of: find.byTooltip('Rename'),
      matching: find.byType(IconButton),
    ));
    expect(rename.onPressed, isNull);
    expect(find.byTooltip('Share trip'), findsNothing);
    expect(find.byTooltip('Delete trip'), findsNothing);

    // The Bookings view's add menu is likewise disabled, not hidden. The
    // tab tap itself stays allowed offline — switching views is pure view
    // work on the cached copy.
    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();
    final addBooking = _labeledButton<TextButton>(tester, 'Add booking');
    expect(addBooking.onPressed, isNull);
  });

  testWidgets('Retry re-fetches live and exits offline mode',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    await cache.writeTrip(_trip('Athens Trip'));
    final service = _QueuedTripsApiService(
        [http.ClientException('down'), _trip('Athens Trip (live)')]);

    await _pumpDetail(tester, service, cache);
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline — showing saved copy from'),
        findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(service.calls, 2);
    expect(find.textContaining('Offline — showing saved copy from'),
        findsNothing);
    expect(find.text('Athens Trip (live)'), findsWidgets);
    final refine = _labeledButton<FilledButton>(tester, 'Refine with AI');
    expect(refine.onPressed, isNotNull, reason: 'back online — re-enabled');
  });

  testWidgets('an HTTP 403 shows the error page, never the cached copy',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    await cache.writeTrip(_trip('Athens Trip'));
    final service =
        _QueuedTripsApiService([Exception('Failed to load trip (403)')]);

    await _pumpDetail(tester, service, cache);
    await tester.pumpAndSettle();

    expect(find.text('Could not load this trip'), findsOneWidget);
    expect(find.text('Acropolis'), findsNothing);
    expect(find.textContaining('Offline — showing saved copy from'),
        findsNothing);
  });

  testWidgets('a network failure with no cached copy shows the error page',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([http.ClientException('down')]);

    await _pumpDetail(tester, service, TripCache('u1'));
    await tester.pumpAndSettle();

    expect(find.text('Could not load this trip'), findsOneWidget);
    expect(find.textContaining('Offline — showing saved copy from'),
        findsNothing);
  });

  testWidgets(
      'quiet network failure (pull-to-refresh) enters offline mode without '
      'swapping the on-screen trip', (WidgetTester tester) async {
    final cache = TripCache('u1');
    final service = _QueuedTripsApiService(
        [_trip('Athens Trip (live)'), http.ClientException('down')]);

    await _pumpDetail(tester, service, cache);
    await tester.pumpAndSettle();
    expect(find.text('Athens Trip (live)'), findsWidgets);

    // Plant a divergent, older cache entry AFTER the initial load's
    // write-through, so a swap-from-cache would be visible and the banner's
    // timestamp provably comes from the cache entry, not DateTime.now().
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'trip_cache.u1.trip.t1',
      jsonEncode({
        'saved_at': DateTime.now()
            .subtract(const Duration(days: 2))
            .toIso8601String(),
        'trip': _trip('Cached Stale Copy').toJson(),
      }),
    );

    await _triggerRefresh(tester);
    await tester.pumpAndSettle();
    expect(service.calls, 2);

    // Offline mode entered: banner up, dated from the cache entry.
    expect(find.textContaining('Offline — showing saved copy from'),
        findsOneWidget);
    expect(find.textContaining('2 days ago'), findsOneWidget);
    // The on-screen trip is untouched — never swapped for the cached copy.
    expect(find.text('Athens Trip (live)'), findsWidgets);
    expect(find.text('Cached Stale Copy'), findsNothing);
    expect(find.text('Could not load this trip'), findsNothing);

    // Mutation affordances are guarded, same as a loud offline entry.
    final refine = _labeledButton<FilledButton>(tester, 'Refine with AI');
    expect(refine.onPressed, isNull);
    final addPlace = _labeledButton<TextButton>(tester, 'Add place');
    expect(addPlace.onPressed, isNull);
  });

  testWidgets('quiet NON-network failure stays fully silent',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    final service = _QueuedTripsApiService(
        [_trip('Athens Trip'), Exception('Failed to load trip (500)')]);

    await _pumpDetail(tester, service, cache);
    await tester.pumpAndSettle();

    await _triggerRefresh(tester);
    await tester.pumpAndSettle();
    expect(service.calls, 2);

    // No banner, no error page, mutations still armed — the PR #51/#53
    // silent-refresh invariant for transient server errors.
    expect(find.textContaining('Offline — showing saved copy from'),
        findsNothing);
    expect(find.text('Could not load this trip'), findsNothing);
    expect(find.text('Athens Trip'), findsWidgets);
    final refine = _labeledButton<FilledButton>(tester, 'Refine with AI');
    expect(refine.onPressed, isNotNull);
  });

  testWidgets(
      'a successful load after a quiet offline entry clears the banner',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    final service = _QueuedTripsApiService([
      _trip('Athens Trip'),
      http.ClientException('down'),
      _trip('Athens Trip (back online)'),
    ]);

    await _pumpDetail(tester, service, cache);
    await tester.pumpAndSettle();

    await _triggerRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline — showing saved copy from'),
        findsOneWidget);

    // Reconnect: another pull-to-refresh succeeds and exits offline mode.
    await _triggerRefresh(tester);
    await tester.pumpAndSettle();
    expect(service.calls, 3);

    expect(find.textContaining('Offline — showing saved copy from'),
        findsNothing);
    expect(find.text('Athens Trip (back online)'), findsWidgets);
    final refine = _labeledButton<FilledButton>(tester, 'Refine with AI');
    expect(refine.onPressed, isNotNull, reason: 'back online — re-enabled');
  });
}
