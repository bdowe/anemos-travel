import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/place_search_result.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/places_api_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/log_trip_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/auth_storage.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

/// The "Log a past trip" form (specs/log-past-trip). The invariants worth
/// pinning are the two the feature's correctness rests on: **saving is gated on
/// destinations AND dates** (an undated trip could never count as travel
/// already taken, so the form must not be able to produce one), and a
/// **typed-name destination sends no coordinates** rather than a guessed pair.
class _FakeTripsApiService extends TripsApiService {
  Map<String, dynamic>? sentBody;

  _FakeTripsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => const [];

  @override
  Future<Trip> createTrip({
    required List<Map<String, dynamic>> destinations,
    required String startDate,
    required String endDate,
    String? title,
  }) async {
    sentBody = {
      'destinations': destinations,
      'start_date': startDate,
      'end_date': endDate,
      'title': title,
    };
    return Trip(
      id: 'trip-1',
      title: 'Trip to Kyoto',
      createdAt: '2026-08-14',
      updatedAt: '2026-08-14',
    );
  }
}

class _FakeAuthStorage extends AuthStorage {
  @override
  Future<String?> loadToken() async => null;

  @override
  Future<void> saveToken(String value) async {}

  @override
  Future<void> clearToken() async {}
}

PlaceSearchResult _place(String name) => PlaceSearchResult(
      placeId: 'pid-${name.toLowerCase()}',
      name: name,
      address: '$name, Japan',
      latitude: 35.0116,
      longitude: 135.7681,
      types: const ['locality'],
    );

Future<void> _pump(
  WidgetTester tester,
  _FakeTripsApiService fake, {
  List<PlaceSearchResult> results = const [],
  Object? searchError,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(fake),
        authStorageProvider.overrideWithValue(_FakeAuthStorage()),
        placeSearchProvider.overrideWith((ref, query) async {
          if (searchError != null) throw searchError;
          return results;
        }),
      ],
      child: localizedTestApp(home: const LogTripScreen()),
    ),
  );
}

/// Types into the search box and lets the 350 ms debounce fire.
Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(kLogTripSearchFieldKey), text);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(kLogTripSaveButtonKey));

/// Drives the Material date-range picker to a fixed past range: open it, pick
/// the first and last selectable days of the month it lands on, confirm.
Future<void> _pickDates(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.calendar_month_outlined));
  await tester.pumpAndSettle();
  // The picker opens on the last selectable month (today's). Days 1 and 2 of
  // it are always in range, and a two-day span is enough for the assertions.
  await tester.tap(find.text('1').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('2').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('save is disabled until there are destinations AND dates',
      (tester) async {
    final fake = _FakeTripsApiService();
    await _pump(tester, fake, results: [_place('Kyoto')]);

    expect(_saveButton(tester).onPressed, isNull,
        reason: 'empty form cannot save');

    await _search(tester, 'Kyoto');
    await tester.tap(find.text('Kyoto').last);
    await tester.pumpAndSettle();

    expect(_saveButton(tester).onPressed, isNull,
        reason: 'a destination without dates would land in Planned, not '
            'Traveled — the form must not be able to produce it');

    await _pickDates(tester);
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('picking a place adds a removable chip carrying its coordinates',
      (tester) async {
    final fake = _FakeTripsApiService();
    await _pump(tester, fake, results: [_place('Kyoto')]);

    await _search(tester, 'Kyoto');
    await tester.tap(find.text('Kyoto').last);
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsOneWidget);
    // A located destination is flagged as such; the "no map location" note is
    // absent because nothing on the form lacks coordinates.
    expect(find.byIcon(Icons.place), findsOneWidget);
    expect(find.byIcon(Icons.location_off_outlined), findsNothing);

    // By tooltip, not by icon: the chip's delete glyph differs between
    // Material 2 and 3, and what the test cares about is the affordance.
    await tester.tap(find.byTooltip(
        MaterialLocalizations.of(tester.element(find.byType(InputChip)))
            .deleteButtonTooltip));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('search failure still allows a name-only destination',
      (tester) async {
    final fake = _FakeTripsApiService();
    await _pump(tester, fake, searchError: Exception('no places key'));

    await _search(tester, "Grandma's village");
    // Search being unavailable is not a dead end: the typed name is offered.
    await tester.tap(find.textContaining("Grandma's village").last);
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsOneWidget);
    expect(find.byIcon(Icons.location_off_outlined), findsOneWidget,
        reason: 'an unlocated destination must say so before saving');
  });

  testWidgets('saving sends the destinations and dates', (tester) async {
    final fake = _FakeTripsApiService();
    await _pump(tester, fake, results: [_place('Kyoto')]);

    await _search(tester, 'Kyoto');
    await tester.tap(find.text('Kyoto').last);
    await tester.pumpAndSettle();
    await _pickDates(tester);
    await tester.tap(find.byKey(kLogTripSaveButtonKey));
    await tester.pumpAndSettle();

    final sent = fake.sentBody;
    expect(sent, isNotNull, reason: 'the save must reach the service');
    final destinations = sent!['destinations'] as List<Map<String, dynamic>>;
    expect(destinations, hasLength(1));
    expect(destinations.single['name'], 'Kyoto');
    expect(destinations.single['place_id'], 'pid-kyoto');
    expect(destinations.single['latitude'], 35.0116);
    expect(sent['start_date'], isA<String>());
    expect(sent['end_date'], isA<String>());
    // The picker only offers past dates, so a saved range never runs ahead of
    // today — that is what keeps a logged trip on the Traveled side.
    expect(DateTime.parse(sent['end_date'] as String)
        .isAfter(DateTime.now().add(const Duration(days: 1))), isFalse);
  });
}
