import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';

import 'support/l10n_test_app.dart';

/// Records mint calls and returns a fixed token so the built per-event .ics
/// URL is deterministic.
class _FakeTripsApiService extends TripsApiService {
  int mintCalls = 0;

  _FakeTripsApiService() : super(ApiClient(baseUrl: 'http://test/api/v1'));

  @override
  Future<String> mintExportToken(String tripId) {
    mintCalls++;
    return Future.value('tok-123');
  }
}

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

const _datedStay = Accommodation(
  id: 'a1',
  name: 'Casa do Brian',
  provider: 'Airbnb',
  address: 'Lisbon',
  checkIn: '2026-09-04',
  checkOut: '2026-09-06',
);

const _undatedStay = Accommodation(id: 'a2', name: 'Somewhere in Porto');

const _datedLeg = TripSegment(
  id: 's1',
  mode: 'flight',
  origin: 'LIS',
  destination: 'OPO',
  departDate: '2026-09-04',
  arriveDate: '2026-09-05',
);

Future<(_FakeTripsApiService, _FakeUrlLauncher)> _pump(
  WidgetTester tester, {
  required List<BookingDetailRow> rows,
}) async {
  final service = _FakeTripsApiService();
  final launcher = _FakeUrlLauncher();
  UrlLauncherPlatform.instance = launcher;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(service),
        analyticsApiServiceProvider.overrideWithValue(_NoopAnalytics()),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(child: Column(children: rows)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (service, launcher);
}

Finder _calendarButton() => find.byTooltip('Add to calendar');

void main() {
  testWidgets('dated stay shows the menu; undated stays do not',
      (tester) async {
    await _pump(tester, rows: const [
      BookingDetailRow.stay(tripId: 't1', stay: _datedStay),
      BookingDetailRow.stay(tripId: 't1', stay: _undatedStay),
    ]);
    expect(_calendarButton(), findsOneWidget);
  });

  testWidgets('Google entry launches a prefilled calendar.google.com link',
      (tester) async {
    final (service, launcher) = await _pump(tester, rows: const [
      BookingDetailRow.stay(
          tripId: 't1', stay: _datedStay, appleCalendarEnabled: true),
    ]);

    await tester.tap(_calendarButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google Calendar'));
    await tester.pumpAndSettle();

    expect(launcher.launched, hasLength(1));
    final uri = Uri.parse(launcher.launched.single);
    expect(uri.host, 'calendar.google.com');
    expect(uri.queryParameters['action'], 'TEMPLATE');
    expect(uri.queryParameters['text'], 'Stay: Casa do Brian');
    expect(uri.queryParameters['dates'], '20260904/20260906');
    expect(service.mintCalls, 0, reason: 'Google path needs no token');
  });

  testWidgets('Apple entry mints once and launches the per-event .ics',
      (tester) async {
    final (service, launcher) = await _pump(tester, rows: const [
      BookingDetailRow.stay(
          tripId: 't1', stay: _datedStay, appleCalendarEnabled: true),
    ]);

    await tester.tap(_calendarButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple Calendar (.ics)'));
    await tester.pumpAndSettle();

    expect(service.mintCalls, 1);
    expect(launcher.launched.single,
        'http://test/api/v1/export/tok-123/event/stay/a1.ics');
  });

  testWidgets('segment row builds the mode-and-route title', (tester) async {
    final (_, launcher) = await _pump(tester, rows: const [
      BookingDetailRow.segment(
          tripId: 't1', segment: _datedLeg, appleCalendarEnabled: true),
    ]);

    await tester.tap(_calendarButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google Calendar'));
    await tester.pumpAndSettle();

    final uri = Uri.parse(launcher.launched.single);
    expect(uri.queryParameters['text'], 'Flight: LIS → OPO');
    expect(uri.queryParameters['dates'], '20260904/20260906');
  });

  testWidgets('appleCalendarEnabled: false renders the Apple entry disabled',
      (tester) async {
    final (service, launcher) = await _pump(tester, rows: const [
      BookingDetailRow.stay(tripId: 't1', stay: _datedStay),
    ]);

    await tester.tap(_calendarButton());
    await tester.pumpAndSettle();
    final item = tester.widget<PopupMenuItem<String>>(find.ancestor(
      of: find.text('Apple Calendar (.ics)'),
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem<String>),
    ));
    expect(item.enabled, isFalse);

    await tester.tap(find.text('Apple Calendar (.ics)'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(service.mintCalls, 0);
    expect(launcher.launched, isEmpty);
  });
}
