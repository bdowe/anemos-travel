import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

/// A trips service whose getTrip returns [trip] (or throws when null), and
/// whose mintExportToken records the call and hands back a fixed token. Its
/// ApiClient carries a known base so the built export URL is deterministic.
class _FakeTripsApiService extends TripsApiService {
  final Trip? trip;
  final Object? getError;
  int mintCalls = 0;

  _FakeTripsApiService({this.trip, this.getError})
      : super(ApiClient(baseUrl: 'http://test/api/v1'));

  @override
  Future<Trip> getTrip(String id) =>
      trip != null ? Future.value(trip) : Future.error(getError!);

  @override
  Future<String> mintExportToken(String tripId) {
    mintCalls++;
    return Future.value('tok-123');
  }
}

/// Captures launched URLs instead of hitting a platform.
class _FakeUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

/// No-op analytics so tracked_launch's fire-and-forget record never touches
/// the network in the test env.
class _NoopAnalytics extends AnalyticsApiService {
  _NoopAnalytics() : super(ApiClient(baseUrl: 'http://test/api/v1'));

  @override
  Future<void> recordBookingLinkClicked({
    String? tripId,
    String? todoKey,
    String? provider,
    String? surface,
    String? kind,
  }) =>
      Future.value();
}

Trip _trip({String? access}) => Trip(
      id: 't1',
      title: 'Athens Trip',
      access: access,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
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

Future<void> _pump(
  WidgetTester tester,
  _FakeTripsApiService service, {
  TripCache? cache,
  _FakeUrlLauncher? launcher,
}) async {
  if (launcher != null) UrlLauncherPlatform.instance = launcher;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(service),
        tripCacheProvider.overrideWithValue(cache ?? TripCache('u1')),
        analyticsApiServiceProvider.overrideWithValue(_NoopAnalytics()),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('owner sees Print and Add-to-calendar in the share menu',
      (tester) async {
    await _pump(tester, _FakeTripsApiService(trip: _trip()));

    await tester.tap(find.byTooltip('Share trip'));
    await tester.pumpAndSettle();

    expect(find.text('Print / Save as PDF'), findsOneWidget);
    expect(find.text('Add to calendar'), findsOneWidget);
  });

  testWidgets('tapping Print mints a token then launches the print URL',
      (tester) async {
    final service = _FakeTripsApiService(trip: _trip());
    final launcher = _FakeUrlLauncher();
    await _pump(tester, service, launcher: launcher);

    await tester.tap(find.byTooltip('Share trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print / Save as PDF'));
    await tester.pumpAndSettle();

    expect(service.mintCalls, 1);
    expect(launcher.launched,
        ['http://test/api/v1/export/tok-123/print.html']);
  });

  testWidgets('tapping Add-to-calendar launches the .ics URL',
      (tester) async {
    final service = _FakeTripsApiService(trip: _trip());
    final launcher = _FakeUrlLauncher();
    await _pump(tester, service, launcher: launcher);

    await tester.tap(find.byTooltip('Share trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to calendar'));
    await tester.pumpAndSettle();

    expect(service.mintCalls, 1);
    expect(launcher.launched,
        ['http://test/api/v1/export/tok-123/calendar.ics']);
  });

  testWidgets('a non-owner (viewer) never sees the share menu or exports',
      (tester) async {
    await _pump(tester, _FakeTripsApiService(trip: _trip(access: 'viewer')));

    expect(find.byTooltip('Share trip'), findsNothing);
    expect(find.text('Print / Save as PDF'), findsNothing);
    expect(find.text('Add to calendar'), findsNothing);
  });

  testWidgets('offline hides the share menu (export needs the network)',
      (tester) async {
    final cache = TripCache('u1');
    await cache.writeTrip(_trip());
    // getTrip fails with a cached copy present => offline read-only mode.
    await _pump(
      tester,
      _FakeTripsApiService(getError: http.ClientException('offline')),
      cache: cache,
    );

    expect(find.text('Acropolis'), findsOneWidget); // cached copy renders
    expect(find.byTooltip('Share trip'), findsNothing);
    expect(find.text('Print / Save as PDF'), findsNothing);
  });
}
