import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/local_guide.dart';
import 'package:travel_route_planner/models/local_recommendation.dart';
import 'package:travel_route_planner/providers/local_provider.dart';
import 'package:travel_route_planner/screens/local_admin_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/local_api_service.dart';

/// Serves canned admin payloads instead of hitting the network. [failSources]
/// is mutable so a test can fail the first sources load, then flip it and
/// exercise the retry affordance.
class _FakeLocalApi implements LocalApiService {
  final List<Map<String, dynamic>> sources;
  final List<Map<String, dynamic>> drafts;
  final List<Map<String, dynamic>> coverageRows;
  bool failSources;

  _FakeLocalApi({
    this.sources = const [],
    this.drafts = const [],
    this.coverageRows = const [],
    this.failSources = false,
  });

  @override
  ApiClient get apiClient => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listSources() async {
    if (failSources) throw Exception('boom');
    return sources;
  }

  @override
  Future<List<Map<String, dynamic>>> listByStatus(String status) async =>
      drafts;

  @override
  Future<List<Map<String, dynamic>>> coverage() async => coverageRows;

  @override
  Future<Map<String, dynamic>> createSource(Map<String, dynamic> fields) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> ingest({
    required String sourceId,
    required String city,
    required String kind,
    required String rawText,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> publish(String id) async {}

  @override
  Future<List<LocalRecommendation>> searchRecommendations(
    String city, {
    String? category,
  }) async =>
      [];

  @override
  Future<List<LocalGuide>> guides([String? city]) async => [];

  @override
  Future<({LocalGuide guide, List<LocalRecommendation> recommendations})>
      guideById(String id) => throw UnimplementedError();
}

Future<void> _pump(
  WidgetTester tester,
  _FakeLocalApi api, {
  Size surface = const Size(360, 690),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [localApiServiceProvider.overrideWithValue(api)],
      child: const MaterialApp(home: LocalAdminScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'overflow floor: coverage table with long city names at 360px '
      'renders without errors', (tester) async {
    final api = _FakeLocalApi(
      sources: [
        {'id': 's1', 'name': 'Yiannis the fisherman'},
      ],
      coverageRows: [
        {
          'city': 'Santa Cruz de Tenerife y su área metropolitana entera',
          'published': 12,
          'draft': 345,
        },
        {
          'city': 'Thessaloniki and the greater Chalkidiki peninsula',
          'published': 3,
          'draft': 1,
        },
      ],
    );
    await _pump(tester, api);

    await tester.tap(find.text('Coverage'));
    await tester.pumpAndSettle();

    expect(find.byType(DataTable), findsOneWidget);
    // The table sits in a horizontal scroller, so long cities scroll instead
    // of striping the pane with a RenderFlex overflow.
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'overflow floor: review card missing coordinates at 320px '
      'keeps the hint and Publish button without errors', (tester) async {
    final api = _FakeLocalApi(
      sources: [
        {'id': 's1', 'name': 'Yiannis'},
      ],
      drafts: [
        {
          'id': 'd1',
          'name': 'A taverna with an extremely long name that must ellipsize',
          'city': 'Chania',
          'neighborhood': 'Old Venetian Harbour',
          'category': 'restaurant',
          'source_name': 'Yiannis the fisherman',
          'tip': 'Go at sunset and ask for the catch of the day.',
          'place_verified': false,
          // No latitude/longitude → the "needs coordinates" hint renders.
        },
      ],
    );
    await _pump(tester, api, surface: const Size(320, 690));

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('Needs coordinates to publish'), findsOneWidget);
    expect(find.text('Publish'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty review queue still supports pull-to-refresh',
      (tester) async {
    final api = _FakeLocalApi(
      sources: [
        {'id': 's1', 'name': 'Yiannis'},
      ],
    );
    await _pump(tester, api);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('No drafts to review'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);

    // The pull gesture works from the empty state (the branch used to sit
    // outside any scrollable, so pull-to-refresh was dead exactly here).
    await tester.fling(
        find.text('No drafts to review'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(find.text('No drafts to review'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sources load failure surfaces a visible inline retry',
      (tester) async {
    final api = _FakeLocalApi(
      sources: [
        {'id': 's1', 'name': 'Yiannis'},
      ],
      failSources: true,
    );
    await _pump(tester, api);

    // The failure renders where the dropdown would be — top of the form,
    // not buried at the bottom of the ListView.
    expect(find.textContaining('Could not load sources'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Local source'), findsNothing);

    api.failSources = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load sources'), findsNothing);
    expect(find.text('Local source'), findsOneWidget);
  });
}
