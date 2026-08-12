import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

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
}

Trip _trip(String id, String title) => Trip(
      id: id,
      title: title,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpList(
    WidgetTester tester, _QueuedTripsApiService service, TripCache cache) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(service),
        tripCacheProvider.overrideWithValue(cache),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripsListScreen()),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('network failure shows the cached list under an offline banner',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    await cache.writeList([_trip('a', 'Athens Trip')]);
    final service = _QueuedTripsApiService([http.ClientException('down')]);

    await _pumpList(tester, service, cache);
    await tester.pumpAndSettle();

    expect(find.text('Athens Trip'), findsOneWidget);
    expect(find.textContaining('Offline — showing saved copy from'),
        findsOneWidget);
    expect(find.text('Could not load trips'), findsNothing);
  });

  testWidgets('banner Retry re-attempts the live fetch and clears on success',
      (WidgetTester tester) async {
    final cache = TripCache('u1');
    await cache.writeList([_trip('a', 'Athens Trip')]);
    final service = _QueuedTripsApiService([
      http.ClientException('down'),
      [_trip('a', 'Athens Trip'), _trip('b', 'Lisbon Trip')]
    ]);

    await _pumpList(tester, service, cache);
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline — showing saved copy from'),
        findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(service.calls, 2);
    expect(find.textContaining('Offline — showing saved copy from'),
        findsNothing);
    expect(find.text('Lisbon Trip'), findsOneWidget);
  });

  testWidgets('a network failure with no cached copy keeps the error state',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService([http.ClientException('down')]);

    await _pumpList(tester, service, TripCache('u1'));
    await tester.pumpAndSettle();

    expect(find.text('Could not load trips'), findsOneWidget);
    expect(find.textContaining('Offline — showing saved copy from'),
        findsNothing);
  });
}
