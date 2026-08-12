import 'package:flutter/material.dart';
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

/// A recipient whose only trip is one shared with them must see the
/// "Shared with you" section — not the plan-a-trip empty state. Regression
/// test for the guard branches short-circuiting before the shared fetch.
class _EmptyTripsApiService extends TripsApiService {
  _EmptyTripsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => const <Trip>[];
}

Trip _sharedTrip() => Trip(
      id: 'shared-1',
      title: 'Athens Together',
      startDate: '2026-08-01',
      endDate: '2026-08-05',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpList(WidgetTester tester, {required List<Trip> shared}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_EmptyTripsApiService()),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
        sharedWithMeProvider.overrideWith((ref) async => shared),
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

  testWidgets('shared-only account renders the Shared with you section',
      (WidgetTester tester) async {
    await _pumpList(tester, shared: [_sharedTrip()]);
    await tester.pumpAndSettle();

    expect(find.text('Shared with you'), findsOneWidget);
    expect(find.text('Athens Together'), findsOneWidget);
    expect(find.text('No trips yet'), findsNothing);
  });

  testWidgets('truly empty account still gets the plan-a-trip empty state',
      (WidgetTester tester) async {
    await _pumpList(tester, shared: const []);
    await tester.pumpAndSettle();

    expect(find.text('No trips yet'), findsOneWidget);
    expect(find.text('Shared with you'), findsNothing);
  });
}
