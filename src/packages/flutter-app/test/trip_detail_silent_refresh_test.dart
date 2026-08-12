import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// getTrip answers from a queue: a Trip resolves immediately, a Completer
/// stays pending until the test completes it, an Exception throws.
class _QueuedTripsApiService extends TripsApiService {
  final List<Object> responses;
  int calls = 0;

  _QueuedTripsApiService(this.responses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) {
    final next = responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (next is Trip) return Future.value(next);
    if (next is Completer<Trip>) return next.future;
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

Future<void> _triggerRefresh(WidgetTester tester) async {
  await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
  await tester.pump(); // start the indicator
  await tester.pump(const Duration(seconds: 1)); // cross the arm threshold
}

void main() {
  testWidgets('pull-to-refresh updates in place with no full-screen spinner',
      (WidgetTester tester) async {
    final pending = Completer<Trip>();
    final service = _QueuedTripsApiService([_trip('Athens Trip'), pending]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripsApiServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Acropolis'), findsOneWidget);

    await _triggerRefresh(tester);
    expect(service.calls, 2);

    // Mid-refresh the trip stays on screen — the loud path would have
    // replaced the CustomScrollView with a centered spinner.
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.text('Acropolis'), findsOneWidget);

    pending.complete(_trip('Athens Trip (updated)'));
    await tester.pumpAndSettle();
    expect(find.text('Athens Trip (updated)'), findsWidgets);
  });

  testWidgets('a failed silent refresh keeps showing the stale trip',
      (WidgetTester tester) async {
    final service = _QueuedTripsApiService(
        [_trip('Athens Trip'), Exception('network down')]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripsApiServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Acropolis'), findsOneWidget);

    await _triggerRefresh(tester);
    await tester.pumpAndSettle();

    // No error page, no blanking — the stale trip stays.
    expect(find.text('Could not load this trip'), findsNothing);
    expect(find.text('Acropolis'), findsOneWidget);
  });
}
