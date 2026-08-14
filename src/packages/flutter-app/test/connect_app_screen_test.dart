import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/api_client_provider.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/screens/auth_screen.dart';
import 'package:travel_route_planner/screens/connect_app_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/auth_storage.dart';
import 'package:travel_route_planner/services/pending_connect.dart';

import 'support/l10n_test_app.dart';

/// The consent screen (specs/mcp-connector) must: show the requesting app's
/// name with an unverified caution, list scopes in plain language, render the
/// expired state when the request token is stale — and never present an
/// approve action that cannot work.
///
/// The last part is the 2026-08-14 production bug: a signed-out user was shown
/// a screen whose only button was "Sign in", read it as approval, and left
/// through SSO — which navigated the page away and discarded the request, so
/// no decision ever reached the server. Signed-out now hands off to sign-in
/// itself and remembers the request across the round trip.

class _FakeAuthStorage extends AuthStorage {
  String? token;
  @override
  Future<String?> loadToken() async => token;
  @override
  Future<void> saveToken(String value) async => token = value;
  @override
  Future<void> clearToken() async => token = null;
}

/// Never resolves, so `AuthState.initialized` stays false — the "session is
/// still restoring" window.
class _HangingAuthStorage extends AuthStorage {
  @override
  Future<String?> loadToken() => Completer<String?>().future;
}

/// Serves the consent endpoints without a network. The decision path can be
/// given its own status so a 200-context / 401-decision combination — exactly
/// what a dead session produces — is expressible.
class _StubClient extends http.BaseClient {
  final int status;
  final String body;
  final int? decideStatus;
  final String decideBody;

  _StubClient({
    this.status = 200,
    this.body = '',
    this.decideStatus,
    this.decideBody = '{"redirect_url":"https://claude.ai/cb?code=x"}',
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final decision = request.url.path.endsWith('/decision');
    return http.StreamedResponse(
      Stream.value(utf8.encode(decision ? decideBody : body)),
      decision ? (decideStatus ?? 200) : status,
      headers: {'content-type': 'application/json'},
    );
  }
}

ProviderContainer _container(
  http.Client client, {
  bool signedIn = false,
  AuthStorage? storage,
}) {
  final api = ApiClient(baseUrl: 'http://test/api/v1', client: client);
  final container = ProviderContainer(overrides: <Override>[
    apiClientProvider.overrideWithValue(api),
    authStorageProvider.overrideWithValue(storage ?? _FakeAuthStorage()),
  ]);
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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('signed-out user is taken to sign-in, request remembered',
      (tester) async {
    final container = _container(_StubClient(body: _contextBody));
    await _pump(tester, container);

    // Handed off rather than shown a button that cannot approve.
    expect(find.byType(AuthScreen), findsOneWidget);

    // The request survives on-device, which is what lets SSO — a full-page
    // navigation away and back — return here instead of the app shell.
    expect(await const PendingConnectStore().take(), 'gt_rq_test');
  });

  testWidgets('signed-in user sees the request and both actions',
      (tester) async {
    final container =
        _container(_StubClient(body: _contextBody), signedIn: true);
    await _pump(tester, container);

    expect(find.textContaining('ChatGPT'), findsWidgets);
    expect(find.textContaining("hasn't been verified"), findsOneWidget);
    expect(find.text('Create trips in your account and see your trip list'),
        findsOneWidget);
    expect(find.text("Search Anemos's local recommendations"), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });

  testWidgets('a still-restoring session shows no approve action',
      (tester) async {
    final container = _container(
      _StubClient(body: _contextBody),
      storage: _HangingAuthStorage(),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: localizedTestApp(
        home: const ConnectAppScreen(requestToken: 'gt_rq_test'),
      ),
    ));
    // Not pumpAndSettle: the progress indicator animates forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Neither approve (the token behind it may already be dead) nor a
    // premature bounce to sign-in.
    expect(find.text('Connect'), findsNothing);
    expect(find.byType(AuthScreen), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('expired request token renders the start-over state',
      (tester) async {
    final container =
        _container(_StubClient(status: 410, body: '{}'), signedIn: true);
    await _pump(tester, container);

    expect(find.text('This request expired'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
  });

  testWidgets('a failed load offers retry, not start-over', (tester) async {
    final container =
        _container(_StubClient(status: 500, body: '{}'), signedIn: true);
    await _pump(tester, container);

    // "Expired" would send the user back to their AI app for no reason.
    expect(find.text('This request expired'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a session that dies before approving routes to sign-in',
      (tester) async {
    final container = _container(
      _StubClient(body: _contextBody, decideStatus: 401, decideBody: '{}'),
      signedIn: true,
    );
    await _pump(tester, container);

    expect(find.text('Connect'), findsOneWidget);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // A 401 is recoverable, so it must not surface as a dead-end error.
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(await const PendingConnectStore().take(), 'gt_rq_test');
  });
}
