import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/chat_session.dart';
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
import 'package:travel_route_planner/widgets/up_next_trip_card.dart';

import 'support/l10n_test_app.dart';

/// The "Happening now" card on the trips list (specs/happening-now): promoted
/// above the continue section and the Upcoming run, the trip's plain card
/// REPLACED rather than repeated (spec.md's 2026-08-15 amendment), tap-through
/// to the trip detail, and offline-cache parity.
///
/// Dates are relative to DateTime.now() so "today" is always live.
class _QueuedTripsApiService extends TripsApiService {
  final List<Object> responses;
  int calls = 0;

  _QueuedTripsApiService(this.responses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() {
    final next =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (next is List<Trip>) return Future.value(next);
    return Future.error(next);
  }

  /// Serves the tapped trip to the pushed detail screen without a network.
  @override
  Future<Trip> getTrip(String id) async {
    for (final r in responses) {
      if (r is List<Trip>) {
        for (final t in r) {
          if (t.id == id) return t;
        }
      }
    }
    throw StateError('no queued trip $id');
  }
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _rel(int days) => _iso(DateTime.now().add(Duration(days: days)));

Trip _trip(String id, String title, {String? start, String? end}) => Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

/// Yesterday → tomorrow: today is Day 2 of 3.
Trip _liveTrip() => _trip('live', 'Athens Trip', start: _rel(-1), end: _rel(1));

ChatSessionSummary _chat() => ChatSessionSummary(
      chatId: 'c1',
      title: 'Weekend in Rome',
      preview: 'Thinking about museums…',
      messageCount: 3,
      createdAt: '2026-06-01T10:00:00Z',
      updatedAt: '2026-06-01T10:00:00Z',
    );

Future<void> _pumpList(
  WidgetTester tester,
  _QueuedTripsApiService service, {
  TripCache? cache,
  List<ChatSessionSummary> chats = const [],
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(service),
        tripCacheProvider.overrideWithValue(cache ?? TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => chats),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripsListScreen()),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('live card renders above the continue section and above My Trips',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([
      [
        _trip('future', 'Lisbon Trip', start: _rel(5), end: _rel(8)),
        _liveTrip()
      ]
    ]);

    await _pumpList(tester, service, chats: [_chat()]);
    await tester.pumpAndSettle();

    expect(find.byType(LiveTripCard), findsOneWidget);
    final cardY = tester.getTopLeft(find.byType(LiveTripCard)).dy;
    final continueY =
        tester.getTopLeft(find.text('Continue where you left off')).dy;
    final tripCardY = tester.getTopLeft(find.text('Lisbon Trip')).dy;
    expect(cardY, lessThan(continueY));
    expect(continueY, lessThan(tripCardY));

    // The hero REPLACES the plain card: one copy on the screen, and it is
    // the hero's. A trip you are ON is not "Upcoming".
    expect(find.text('Athens Trip'), findsOneWidget);
    expect(
      find.descendant(
          of: find.byType(LiveTripCard), matching: find.text('Athens Trip')),
      findsOneWidget,
    );
    // The genuinely-upcoming trip still lists. Asserting BOTH is what pins
    // the filter to the promoted id: a filter on "has started" would also
    // vanish a second, non-promoted in-progress trip.
    expect(find.text('Lisbon Trip'), findsOneWidget);
  });

  testWidgets('live card shows trip progress and the Live pill',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([
      [_liveTrip()]
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(LiveTripCard), findsOneWidget);
    expect(find.text('Day 2 of 3'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
  });

  testWidgets('the live hero carries the plain card facts it replaced',
      (WidgetTester tester) async {
    // The dedupe is only honest while the hero shows at least what the row
    // showed, so the facts the row would have printed are asserted INSIDE the
    // hero. Its own duration chip stays off: "Day 2 of 3" already says 3.
    final service = _QueuedTripsApiService([
      [
        Trip(
          id: 'live',
          title: 'Athens Trip',
          summary: 'Three days of ruins and coffee.',
          startDate: _rel(-1),
          endDate: _rel(1),
          cities: const ['Athens', 'Piraeus'],
          itemCount: 10,
          bookingTotal: 3,
          bookingBooked: 0,
          stayTotal: 2,
          shared: true,
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
        )
      ]
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    Finder inHero(Finder f) =>
        find.descendant(of: find.byType(LiveTripCard), matching: f);

    expect(inHero(find.text('0/3 booked')), findsOneWidget);
    expect(inHero(find.text('2 stays')), findsOneWidget);
    expect(inHero(find.text('10 places')), findsOneWidget);
    expect(inHero(find.text('Shared')), findsOneWidget);
    expect(inHero(find.text('2 cities')), findsOneWidget);
    expect(inHero(find.text('Athens & Piraeus')), findsOneWidget);
    expect(inHero(find.text('Three days of ruins and coffee.')), findsOneWidget);
    expect(find.text('3 days'), findsNothing);
  });

  testWidgets('an end-less live trip is promoted, not filed under Past',
      (WidgetTester tester) async {
    // tripIsPast and the live rule disagree about end-less trips, so the
    // partition's live exemption is what keeps a Live-pill trip out of the
    // collapsed group — the promotion only removes it from the Upcoming run.
    final service = _QueuedTripsApiService([
      [_trip('live', 'Athens Trip', start: _rel(-1))]
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(LiveTripCard), findsOneWidget);
    expect(find.text('Athens Trip'), findsOneWidget);
    expect(find.text('Past trips'), findsNothing);
  });

  testWidgets('tapping the live card opens the trip detail screen',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([
      [_liveTrip()]
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(LiveTripCard));
    await tester.pumpAndSettle();

    expect(find.byType(TripDetailScreen), findsOneWidget);
  });

  testWidgets('no live trip means no card', (WidgetTester tester) async {
    final service = _QueuedTripsApiService([
      [
        _trip('past', 'Old Trip', start: _rel(-9), end: _rel(-2)),
        _trip('future', 'Lisbon Trip', start: _rel(5), end: _rel(8)),
      ]
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.byType(LiveTripCard), findsNothing);
  });

  testWidgets('live card still renders from the offline cache',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    await cache.writeList([_liveTrip()]);
    final service = _QueuedTripsApiService([http.ClientException('down')]);

    await _pumpList(tester, service, cache: cache);
    await tester.pumpAndSettle();

    expect(find.textContaining('Offline — showing saved copy from'),
        findsOneWidget);
    expect(find.byType(LiveTripCard), findsOneWidget);
    expect(find.text('Day 2 of 3'), findsOneWidget);
    // The cache is its own path into tripsProvider, so it gets its own
    // dedupe pin.
    expect(find.text('Athens Trip'), findsOneWidget);
  });

  testWidgets('wide layouts cap the list content at 700px, phones fill',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([
      [_trip('t1', 'Lisbon Trip', start: _rel(30), end: _rel(33))],
    ]);

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    // The single future-dated trip renders as the promoted Up-next hero, so
    // it is the measured content (same 700px PageContainer cap either way).
    final wideCard = tester.getSize(find.byType(UpNextTripCard));
    expect(wideCard.width, lessThanOrEqualTo(700));
    // Centered: symmetric gutters.
    final left = tester.getTopLeft(find.byType(UpNextTripCard)).dx;
    final right = 1200 - tester.getTopRight(find.byType(UpNextTripCard)).dx;
    expect((left - right).abs(), lessThan(2));

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    final phoneCard = tester.getSize(find.byType(UpNextTripCard));
    expect(phoneCard.width, greaterThan(340)); // full width minus padding
  });

  testWidgets('short list keeps pull-to-refresh armed (always-scrollable)',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([
      [_trip('t1', 'Lisbon Trip', start: _rel(30), end: _rel(33))],
    ]);
    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    // One trip card is far shorter than the viewport; with clamping physics
    // the drag would be swallowed and onRefresh could never fire.
    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(list.physics, isA<AlwaysScrollableScrollPhysics>());

    await tester.fling(find.byType(ListView).first, const Offset(0, 300), 1000);
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
