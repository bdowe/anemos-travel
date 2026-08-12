import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/shared_trip.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/shared_trip_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

/// The shared-trip list must reserve enough bottom padding for the pinned
/// action bar (which is opaque): scrolled to the end, the last row has to sit
/// fully above the bar, not hidden behind it.
class _FakeTripsApiService extends TripsApiService {
  final SharedTrip shared;
  _FakeTripsApiService(this.shared) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<SharedTrip> getSharedTrip(String token) async => shared;
}

Trip _trip() => Trip(
      id: 't1',
      title: 'Lisbon long weekend',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        for (var i = 0; i < 12; i++)
          ItineraryItem(
            id: 'i$i',
            position: i,
            name: 'Stop number $i',
            address: 'Address $i, Lisboa',
            latitude: 0,
            longitude: 0,
            category: 'attraction',
            day: 1 + i ~/ 4,
            city: 'Lisboa',
          ),
      ],
      accommodations: const [
        Accommodation(id: 'a1', name: 'Alfama Guesthouse'),
      ],
    );

void main() {
  testWidgets('last row scrolls fully above the pinned action bar on a phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(
              SharedTrip(trip: _trip(), ownerName: 'Ann'))),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: const SharedTripScreen(token: 'tok')),
      ),
    );
    await tester.pumpAndSettle();

    // Scroll to the very end (clamping physics stop at maxScrollExtent).
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    // The bar's top edge: its primary button minus the container padding
    // above it (AppSpacing.md = 12).
    final barTop =
        tester.getTopLeft(find.bySubtype<FilledButton>().first).dy - 12;
    final lastRow = find.widgetWithText(ListTile, 'Alfama Guesthouse');
    expect(lastRow, findsOneWidget);
    expect(tester.getBottomLeft(lastRow).dy, lessThanOrEqualTo(barTop));
    expect(tester.takeException(), isNull);
  });
}
