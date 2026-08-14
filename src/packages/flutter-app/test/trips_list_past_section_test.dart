import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/collapsible_section.dart';

import 'support/l10n_test_app.dart';

/// The trips list orders by travel date and folds finished trips into a
/// collapsed "Past trips" row (utils/trip_list_order.dart): upcoming cards on
/// top soonest-first, past cards hidden until the row is expanded.
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;
  _FixedTripsApiService(this.trips)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() => Future.value(trips);
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

Future<void> _pumpList(WidgetTester tester, List<Trip> trips) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripsListScreen()),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('past trip hides behind a collapsed row and expands on tap',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      // Server order: newest-created first, i.e. the past trip on top.
      _trip('past', 'Guadalajara', start: _rel(-16), end: _rel(-15)),
      _trip('future', 'Prague Trip', start: _rel(18), end: _rel(52)),
    ]);
    await tester.pumpAndSettle();

    // Collapsed: the row and its count pill show, the past card doesn't.
    expect(find.text('Past trips'), findsOneWidget);
    expect(find.text('1 trip'), findsOneWidget);
    expect(find.text('Prague Trip'), findsOneWidget);
    expect(find.text('Guadalajara'), findsNothing);

    // The upcoming card renders above the collapsed row.
    expect(
      tester.getTopLeft(find.text('Prague Trip')).dy,
      lessThan(tester.getTopLeft(find.text('Past trips')).dy),
    );

    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Guadalajara'), findsOneWidget);

    // Toggling closed hides it again.
    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Guadalajara'), findsNothing);
  });

  testWidgets('upcoming trips reorder soonest-first, ignoring server order',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _trip('far', 'December Trip', start: _rel(120), end: _rel(125)),
      _trip('near', 'Next Week Trip', start: _rel(7), end: _rel(9)),
    ]);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Next Week Trip')).dy,
      lessThan(tester.getTopLeft(find.text('December Trip')).dy),
    );
    // Nothing is past, so no collapsed row appears.
    expect(find.byType(CollapsibleSection), findsNothing);
  });

  testWidgets('all-past account still reaches its trips', (tester) async {
    await _pumpList(tester, [
      _trip('past', 'Old Trip', start: _rel(-9), end: _rel(-2)),
    ]);
    await tester.pumpAndSettle();

    // Not the empty state: the Upcoming header (deliberately kept — it
    // carries the list's only create affordance) sits above the collapsed
    // row, which holds every trip.
    expect(find.text('No trips yet'), findsNothing);
    expect(find.text('Past trips'), findsOneWidget);

    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Old Trip'), findsOneWidget);
  });
}
