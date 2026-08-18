import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart'
    show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/utils/tracked_launch.dart';

/// Captures launch calls instead of hitting a real platform.
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

/// Captures booking-click records; can be told to blow up to prove that
/// analytics failure never blocks the launch.
class _RecordingAnalytics implements AnalyticsApiService {
  @override
  Future<void> recordLandingPromptSubmitted(
          {required String surface, String? kind}) =>
      Future.value();

  @override
  Future<void> recordPendingPromptConsumed({required String surface}) =>
      Future.value();

  @override
  Future<void> recordLegsParityMismatch(
          {required String tripId, required List<String> details}) =>
      Future.value();

  final calls = <Map<String, String?>>[];
  final bool throwOnRecord;

  _RecordingAnalytics({this.throwOnRecord = false});

  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<void> recordItineraryItemAdded({
    required String tripId,
    required String source,
  }) =>
      Future.value();

  @override
  Future<void> recordLandingViewed() => Future.value();

  @override
  Future<void> recordBookingLinkClicked({
    String? tripId,
    String? todoKey,
    String? provider,
    String? surface,
    String? kind,
  }) {
    if (throwOnRecord) throw Exception('analytics is down');
    calls.add({
      'trip_id': tripId,
      'todo_key': todoKey,
      'provider': provider,
      'surface': surface,
      'kind': kind,
    });
    return Future.value();
  }
}

Widget _harness(_RecordingAnalytics analytics, {String url = 'https://duffel.example/offer'}) {
  return ProviderScope(
    overrides: [
      analyticsApiServiceProvider.overrideWithValue(analytics),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => trackedLaunchUrl(
              context,
              url,
              provider: 'duffel',
              surface: 'flight_card',
              tripId: 'trip-1',
            ),
            child: const Text('Book'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late _FakeUrlLauncher launcher;

  setUp(() {
    launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  testWidgets('trackedLaunchUrl records booking_link_clicked then launches',
      (tester) async {
    final analytics = _RecordingAnalytics();
    await tester.pumpWidget(_harness(analytics));

    await tester.tap(find.text('Book'));
    await tester.pump();

    expect(launcher.launched, ['https://duffel.example/offer']);
    expect(analytics.calls, hasLength(1));
    expect(analytics.calls.single['provider'], 'duffel');
    expect(analytics.calls.single['surface'], 'flight_card');
    expect(analytics.calls.single['trip_id'], 'trip-1');
  });

  testWidgets('analytics failure never blocks the launch', (tester) async {
    final analytics = _RecordingAnalytics(throwOnRecord: true);
    await tester.pumpWidget(_harness(analytics));

    await tester.tap(find.text('Book'));
    await tester.pump();

    expect(launcher.launched, ['https://duffel.example/offer']);
  });

  testWidgets('an unparseable/empty url neither records nor launches',
      (tester) async {
    final analytics = _RecordingAnalytics();
    await tester.pumpWidget(_harness(analytics, url: ''));

    await tester.tap(find.text('Book'));
    await tester.pump();

    expect(launcher.launched, isEmpty);
    expect(analytics.calls, isEmpty);
  });
}
