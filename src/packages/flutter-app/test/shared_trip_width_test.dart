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

/// Declutter series: the public shared-trip page caps its content (and the
/// pinned bottom action bar's buttons) at PageContainer's 700px on wide
/// layouts, while phones keep the full-width layout.
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
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Castelo de São Jorge',
          address: 'R. de Santa Cruz do Castelo, Lisboa',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 1,
          city: 'Lisboa',
        ),
      ],
      accommodations: const [
        Accommodation(id: 'a1', name: 'Alfama Guesthouse'),
      ],
    );

Future<void> _pump(WidgetTester tester, {required Size surface}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(
            _FakeTripsApiService(SharedTrip(trip: _trip(), ownerName: 'Ann'))),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const SharedTripScreen(token: 'tok')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('wide layouts cap content and bottom-bar buttons at 700px',
      (tester) async {
    await _pump(tester, surface: const Size(1200, 900));

    final row = find.byType(ListTile).first;
    expect(tester.getSize(row).width, lessThanOrEqualTo(700));
    // Centered: symmetric gutters.
    final left = tester.getTopLeft(row).dx;
    final right = 1200 - tester.getTopRight(row).dx;
    expect((left - right).abs(), lessThan(2));

    // The pinned action bar's primary button shares the same column.
    // (FilledButton.icon builds a private subclass — bySubtype, not byType.)
    final button = find.bySubtype<FilledButton>().first;
    expect(tester.getSize(button).width, lessThanOrEqualTo(700));
    final bLeft = tester.getTopLeft(button).dx;
    final bRight = 1200 - tester.getTopRight(button).dx;
    expect((bLeft - bRight).abs(), lessThan(2));
  });

  testWidgets('phones keep the full-width layout', (tester) async {
    await _pump(tester, surface: const Size(390, 844));
    expect(tester.getSize(find.byType(ListTile).first).width,
        greaterThan(340));
    expect(tester.getSize(find.bySubtype<FilledButton>().first).width,
        greaterThan(340));
  });
}
