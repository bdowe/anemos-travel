import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

/// [TripDetailScreen.openHealthSheet] — the landing half of Home's "Before you
/// go" card. That card lists a trip's open items and can fix none of them, so
/// it opens the sheet that can rather than dropping the traveler on the trip
/// page to go hunting for the health badge.
class _FakeTripsApiService extends TripsApiService {
  final Trip? trip;
  final Object? error;

  /// Counted so the "a refresh must not reopen it" test can prove a second
  /// load actually ran, rather than passing because the fling did nothing.
  int loads = 0;

  _FakeTripsApiService({this.trip, this.error})
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    loads++;
    if (error != null) throw error!;
    return trip!;
  }
}

class _FakeReviewApiService extends TripReviewApiService {
  final TripReview review;
  _FakeReviewApiService(this.review) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripReview> getReview(String tripId, {bool checkHours = false}) async =>
      review;
}

void main() {
  Trip trip() => Trip(
        id: 't1',
        title: 'Northern Europe',
        startDate: '2026-09-01',
        endDate: '2026-09-05',
        createdAt: '2026-07-01',
        updatedAt: '2026-07-01',
        items: [
          ItineraryItem(
            id: 'i0',
            position: 0,
            name: 'Brandenburg Gate',
            address: 'Berlin, Germany',
            latitude: 0,
            longitude: 0,
            category: 'attraction',
            day: 1,
            city: 'Berlin',
          ),
        ],
      );

  const review = TripReview(
    findings: [
      TripFinding(
        severity: 'warn',
        category: 'lodging',
        message: 'No lodging booked for the night of Sep 1.',
        tripId: 't1',
        day: 1,
      ),
    ],
  );

  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<_FakeTripsApiService> pump(
    WidgetTester tester, {
    required bool openHealthSheet,
    Object? loadError,
  }) async {
    useTallViewport(tester);
    final trips = loadError != null
        ? _FakeTripsApiService(error: loadError)
        : _FakeTripsApiService(trip: trip());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(trips),
          tripReviewApiServiceProvider
              .overrideWithValue(_FakeReviewApiService(review)),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(
              tripId: 't1', openHealthSheet: openHealthSheet),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return trips;
  }

  testWidgets('the flag lands with the health sheet already open',
      (tester) async {
    await pump(tester, openHealthSheet: true);

    expect(find.byType(BottomSheet), findsOneWidget);
    // The complete list, on the sheet — with the buttons Home could not host.
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('No lodging booked for the night of Sep 1.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('every other entry point is unchanged — no sheet',
      (tester) async {
    await pump(tester, openHealthSheet: false);

    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('closing it is final — a later refresh must not reopen it',
      (tester) async {
    final trips = await pump(tester, openHealthSheet: true);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(trips.loads, 1);

    Navigator.of(tester.element(find.byType(TripDetailScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);

    // Pull to refresh runs the same _load the arrival hook rides on. Driven
    // through the indicator's own state rather than a fling, and the load
    // count is asserted, so this cannot pass because the gesture missed.
    tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pumpAndSettle();

    expect(trips.loads, greaterThan(1), reason: 'the refresh must have run');
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a failed load opens nothing — the error is what to show',
      (tester) async {
    await pump(tester,
        openHealthSheet: true, loadError: Exception('boom'));

    expect(find.byType(BottomSheet), findsNothing);
  });
}
