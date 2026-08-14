import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/api_client_provider.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/connect_app_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/auth_storage.dart';

import 'support/l10n_test_app.dart';

/// The consent screen (specs/mcp-connector) must: show the requesting app's
/// name with an unverified caution, list scopes in plain language, gate the
/// approve action behind sign-in, and render the expired state when the
/// request token is stale.

class _FakeAuthStorage extends AuthStorage {
  String? token;
  @override
  Future<String?> loadToken() async => token;
  @override
  Future<void> saveToken(String value) async => token = value;
  @override
  Future<void> clearToken() async => token = null;
}

/// Serves the /oauth/authorize/context response (or a 410) without a network.
class _StubClient extends http.BaseClient {
  final int status;
  final String body;
  _StubClient({this.status = 200, this.body = ''});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}

ProviderContainer _container(http.Client client, {bool signedIn = false}) {
  final api = ApiClient(baseUrl: 'http://test/api/v1', client: client);
  final overrides = <Override>[
    apiClientProvider.overrideWithValue(api),
    authStorageProvider.overrideWithValue(_FakeAuthStorage()),
  ];
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  if (signedIn) {
    container.read(authProvider.notifier).adoptSession(
          'session-token',
          UserModel(
            id: 'u1',
            email: 'a@b.c',
            displayName: 'A',
            createdAt: DateTime(2026, 1, 1),
          ),
        );
  }
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: localizedTestApp(
      home: const ConnectAppScreen(requestToken: 'gt_rq_test'),
    ),
  ));
  await tester.pumpAndSettle();
}

const _contextBody =
    '{"client_name":"ChatGPT","scopes":["trips:write","recs:read"]}';

void main() {
  testWidgets('signed-out user is asked to sign in before approving',
      (tester) async {
    final container = _container(_StubClient(body: _contextBody));
    await _pump(tester, container);

    expect(find.textContaining('ChatGPT'), findsWidgets);
    expect(find.textContaining("hasn't been verified"), findsOneWidget);
    expect(find.text('Create trips in your account and see your trip list'),
        findsOneWidget);
    expect(find.text("Search Anemos's local recommendations"),
        findsOneWidget);
    // The approve action must not exist until there's a session to bind to.
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
  });

  testWidgets('signed-in user sees approve and deny actions', (tester) async {
    final container =
        _container(_StubClient(body: _contextBody), signedIn: true);
    await _pump(tester, container);

    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
  });

  testWidgets('expired request token renders the start-over state',
      (tester) async {
    final container = _container(_StubClient(status: 410, body: '{}'));
    await _pump(tester, container);

    expect(find.text('This request expired'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
  });
}
