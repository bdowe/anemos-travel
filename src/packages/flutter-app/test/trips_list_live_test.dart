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

import 'support/l10n_test_app.dart';

/// The "Happening now" card on the trips list (specs/happening-now): promoted
/// above the continue section and My Trips, live trip left in place below,
/// tap-through to the trip detail, and offline-cache parity.
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
      status: 'planned',
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

    // Promoted shortcut, not a filter: the live trip stays in My Trips, so
    // its title shows twice — once on the card, once on its list card.
    expect(find.text('Athens Trip'), findsNWidgets(2));
  });

  testWidgets('live card shows trip progress and the Live pill',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([
      [_liveTrip()]
    ]);

    await _pumpList(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('HAPPENING NOW'), findsOneWidget);
    expect(find.text('Day 2 of 3'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
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
    expect(find.text('HAPPENING NOW'), findsNothing);
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

    final wideCard = tester.getSize(find.byType(Card).first);
    expect(wideCard.width, lessThanOrEqualTo(700));
    // Centered: symmetric gutters.
    final left = tester.getTopLeft(find.byType(Card).first).dx;
    final right = 1200 - tester.getTopRight(find.byType(Card).first).dx;
    expect((left - right).abs(), lessThan(2));

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    final phoneCard = tester.getSize(find.byType(Card).first);
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
