import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/weather.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/weather_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/weather_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// Weather in the itinerary (specs/weather-in-itinerary): a dated day renders a
/// per-day weather chip under its day header; historical reports read "typical";
/// an undated trip renders none. Dates are relative to now so the day headers
/// carry real dates the fake weather report can match on month-day.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Returns a fixed report for every lookup, so the day chips are deterministic.
class _FakeWeatherApiService extends WeatherApiService {
  final WeatherReport report;
  _FakeWeatherApiService(this.report)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<WeatherReport> getTripWeather(String city, String startDate,
          {String? endDate}) async =>
      report;
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

ItineraryItem _item(int pos, String name, int day) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name street, Paris',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: 'Paris',
    );

Trip _twoDayTrip(DateTime start) => Trip(
      id: 't1',
      title: 'Weather Trip',
      status: 'planned',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: _iso(start),
      endDate: _iso(start.add(const Duration(days: 1))),
      items: [
        _item(0, 'Louvre', 1),
        _item(1, 'Orsay', 2),
      ],
    );

Future<void> _pump(
    WidgetTester tester, Trip trip, WeatherReport report) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(_FakeTripsApiService(trip)),
        weatherApiServiceProvider
            .overrideWithValue(_FakeWeatherApiService(report)),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final start = DateTime.now();
  // Month-day keys the two trip days map to.
  final md1 = _iso(start).substring(5);
  final md2 = _iso(start.add(const Duration(days: 1))).substring(5);

  testWidgets('a dated day renders a forecast weather chip under the header',
      (tester) async {
    final report = WeatherReport(
      location: 'Paris, France',
      kind: 'forecast',
      days: [
        WeatherDay(
            date: '2000-$md1', tempMinC: 16, tempMaxC: 24, precipProbability: 70),
        WeatherDay(
            date: '2000-$md2', tempMinC: 15, tempMaxC: 22, precipProbability: 40),
      ],
    );
    await _pump(tester, _twoDayTrip(start), report);

    // Hi/lo temps rendered (rounded) for both days. Both days fold the rain
    // chance into the same Text, so match on substring.
    expect(find.textContaining('24° / 16°'), findsOneWidget);
    expect(find.textContaining('22° / 15°'), findsOneWidget);
    // Each rain tier keeps its glyph through the rainLevel refactor
    // (specs/what-to-wear): 70% → umbrella, 40% → cloud.
    expect(find.textContaining('70% rain'), findsOneWidget);
    expect(find.textContaining('40% rain'), findsOneWidget);
    expect(find.byIcon(Icons.umbrella), findsWidgets);
    expect(find.byIcon(Icons.cloud), findsOneWidget);
    // Forecast, so no "typical" affordance.
    expect(find.textContaining('typical'), findsNothing);
  });

  testWidgets('a historical report labels the chip "typical", not a forecast',
      (tester) async {
    final report = WeatherReport(
      location: 'Paris, France',
      kind: 'historical',
      days: [
        WeatherDay(date: '2000-$md1', tempMinC: 18, tempMaxC: 27, precipMm: 0),
        WeatherDay(date: '2000-$md2', tempMinC: 17, tempMaxC: 26, precipMm: 0),
      ],
    );
    await _pump(tester, _twoDayTrip(start), report);

    expect(find.text('27° / 18°'), findsOneWidget);
    expect(find.textContaining('typical for these dates'), findsWidgets);
    // Historical never shows a rain-chance percentage; dry days keep the
    // sunny glyph (RainLevel.none tier).
    expect(find.textContaining('% rain'), findsNothing);
    expect(find.byIcon(Icons.wb_sunny), findsWidgets);
  });

  test('dayFor falls back to the nearest adjacent day for a missing 02-29',
      () {
    // A historical archive keyed off last year has no 02-29 (the leap day rolls
    // to the prior non-leap year's Mar 1 server-side). dayFor should borrow the
    // adjacent 02-28 entry so Feb 29 still renders a chip.
    final report = WeatherReport(
      kind: 'historical',
      days: [
        WeatherDay(date: '2025-02-28', tempMinC: 3, tempMaxC: 9),
        WeatherDay(date: '2025-03-01', tempMinC: 4, tempMaxC: 10),
      ],
    );
    final resolved = report.dayFor('02-29');
    expect(resolved, isNotNull);
    expect(resolved!.date, '2025-02-28'); // previous day preferred over 03-01
  });

  test('dayFor uses the next day when the previous is also absent', () {
    final report = WeatherReport(
      kind: 'historical',
      days: [WeatherDay(date: '2025-03-01', tempMinC: 4, tempMaxC: 10)],
    );
    expect(report.dayFor('02-29')?.date, '2025-03-01');
  });

  test('dayFor still returns null when no adjacent day exists either', () {
    final report = WeatherReport(
      kind: 'historical',
      days: [WeatherDay(date: '2025-07-04', tempMinC: 18, tempMaxC: 28)],
    );
    expect(report.dayFor('02-29'), isNull);
  });

  testWidgets('an undated trip renders no weather chip', (tester) async {
    final undated = Trip(
      id: 't1',
      title: 'Undated',
      status: 'planned',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', 1),
        _item(1, 'Orsay', 2),
      ],
    );
    final report = WeatherReport(
      location: 'Paris, France',
      kind: 'forecast',
      days: [
        WeatherDay(
            date: '2000-$md1', tempMinC: 16, tempMaxC: 24, precipProbability: 10),
      ],
    );
    await _pump(tester, undated, report);

    expect(find.textContaining('° / '), findsNothing);
    expect(find.text('Day 1'), findsOneWidget); // plain header, no dates
  });
}
