import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/auth_service.dart';
import 'package:travel_route_planner/services/auth_storage.dart';

/// AuthService whose `me` is scripted per test.
class _FakeAuthService extends AuthService {
  final Future<UserModel> Function() onMe;
  _FakeAuthService(this.onMe) : super(baseUrl: 'http://unused');

  @override
  Future<UserModel> me(String token) => onMe();
}

/// In-memory AuthStorage that records whether the token was cleared.
class _FakeAuthStorage extends AuthStorage {
  String? token;
  String? userSnapshot;
  bool cleared = false;
  bool snapshotCleared = false;
  _FakeAuthStorage(this.token, {this.userSnapshot});

  @override
  Future<String?> loadToken() async => token;

  @override
  Future<void> saveToken(String value) async => token = value;

  @override
  Future<void> clearToken() async {
    token = null;
    cleared = true;
  }

  @override
  Future<String?> loadUserSnapshot() async => userSnapshot;

  @override
  Future<void> saveUserSnapshot(String value) async => userSnapshot = value;

  @override
  Future<void> clearUserSnapshot() async {
    userSnapshot = null;
    snapshotCleared = true;
  }
}

UserModel _user({String displayName = 'Traveler'}) => UserModel(
      id: 'u1',
      email: 'traveler@example.com',
      displayName: displayName,
      createdAt: DateTime.utc(2026, 1, 1),
    );

String _snapshotOf(UserModel u) => jsonEncode(u.toJson());

void main() {
  late Duration originalTimeout;

  setUp(() {
    originalTimeout = AuthNotifier.restoreTimeout;
    AuthNotifier.restoreTimeout = const Duration(milliseconds: 50);
  });

  tearDown(() {
    AuthNotifier.restoreTimeout = originalTimeout;
  });

  group('first-ever boot (no cached user snapshot) — serial path', () {
    test('restore timeout fails open signed-out and keeps the token',
        () async {
      final storage = _FakeAuthStorage('stored-token');
      // `me` never completes — simulates a hung/cold backend.
      final service = _FakeAuthService(() => Completer<UserModel>().future);
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.initialized, isTrue);
      expect(notifier.state.isSignedIn, isFalse);
      expect(storage.cleared, isFalse, reason: 'timeout must keep the token');
      expect(storage.token, 'stored-token');
      expect(apiClient.authToken, isNull);
    });

    test('restore error clears the token', () async {
      final storage = _FakeAuthStorage('stored-token');
      final service = _FakeAuthService(() async => throw const AuthException(
          statusCode: 401, message: 'invalid token'));
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.initialized, isTrue);
      expect(notifier.state.isSignedIn, isFalse);
      expect(storage.cleared, isTrue);
      expect(storage.token, isNull);
    });

    test('restore success signs the user in and caches the snapshot',
        () async {
      final storage = _FakeAuthStorage('stored-token');
      final service = _FakeAuthService(() async => _user());
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.initialized, isTrue);
      expect(notifier.state.isSignedIn, isTrue);
      expect(apiClient.authToken, 'stored-token');
      expect(storage.cleared, isFalse);
      expect(storage.userSnapshot, isNotNull,
          reason: 'a successful /auth/me must cache the user for warm boots');
    });
  });

  group('warm boot (token + cached user snapshot) — optimistic path', () {
    test('mounts immediately from the snapshot while me() is still pending',
        () async {
      final storage =
          _FakeAuthStorage('stored-token', userSnapshot: _snapshotOf(_user()));
      // `me` never completes: the shell must still mount from the snapshot.
      final service = _FakeAuthService(() => Completer<UserModel>().future);
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      // Only a couple of microtask-level storage awaits stand between boot
      // and the optimistic state — well under the 50 ms restore timeout.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(notifier.state.initialized, isTrue);
      expect(notifier.state.isSignedIn, isTrue);
      expect(notifier.state.user!.email, 'traveler@example.com');
      expect(apiClient.authToken, 'stored-token');
    });

    test('background revalidation timeout KEEPS the optimistic session',
        () async {
      final storage =
          _FakeAuthStorage('stored-token', userSnapshot: _snapshotOf(_user()));
      final service = _FakeAuthService(() => Completer<UserModel>().future);
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      // Wait past the 50 ms restore timeout: unlike the serial path, a
      // slow/unreachable backend must NOT bounce a cached session.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.isSignedIn, isTrue);
      expect(storage.cleared, isFalse);
      expect(storage.userSnapshot, isNotNull);
      expect(apiClient.authToken, 'stored-token');
    });

    test('background revalidation success refreshes the user in place',
        () async {
      final storage =
          _FakeAuthStorage('stored-token', userSnapshot: _snapshotOf(_user()));
      final service =
          _FakeAuthService(() async => _user(displayName: 'Renamed'));
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.isSignedIn, isTrue);
      expect(notifier.state.user!.displayName, 'Renamed');
      expect(storage.userSnapshot, contains('Renamed'),
          reason: 'the refreshed user must become the next warm-boot snapshot');
    });

    test('background revalidation 401 signs out and clears the session',
        () async {
      final storage =
          _FakeAuthStorage('stored-token', userSnapshot: _snapshotOf(_user()));
      final service = _FakeAuthService(() async => throw const AuthException(
          statusCode: 401, message: 'invalid token'));
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.initialized, isTrue);
      expect(notifier.state.isSignedIn, isFalse);
      expect(storage.cleared, isTrue);
      expect(storage.snapshotCleared, isTrue);
      expect(storage.token, isNull);
      expect(storage.userSnapshot, isNull);
      expect(apiClient.authToken, isNull);
    });

    test('background revalidation 5xx KEEPS the optimistic session',
        () async {
      final storage =
          _FakeAuthStorage('stored-token', userSnapshot: _snapshotOf(_user()));
      final service = _FakeAuthService(() async => throw const AuthException(
          statusCode: 503, message: 'backend degraded'));
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.isSignedIn, isTrue);
      expect(storage.cleared, isFalse);
      expect(apiClient.authToken, 'stored-token');
    });

    test('corrupt snapshot falls back to the serial path', () async {
      final storage =
          _FakeAuthStorage('stored-token', userSnapshot: 'not json{');
      final service = _FakeAuthService(() async => _user());
      final apiClient = ApiClient(baseUrl: 'http://unused');

      final notifier = AuthNotifier(service, storage, apiClient);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.initialized, isTrue);
      expect(notifier.state.isSignedIn, isTrue);
      expect(storage.userSnapshot, _snapshotOf(_user()),
          reason: 'serial restore success must repair the snapshot');
    });
  });

  test('signOutLocally clears the cached user snapshot with the token',
      () async {
    final storage =
        _FakeAuthStorage('stored-token', userSnapshot: _snapshotOf(_user()));
    final service = _FakeAuthService(() async => _user());
    final apiClient = ApiClient(baseUrl: 'http://unused');

    final notifier = AuthNotifier(service, storage, apiClient);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(notifier.state.isSignedIn, isTrue);

    await notifier.signOutLocally();

    expect(notifier.state.isSignedIn, isFalse);
    expect(storage.token, isNull);
    expect(storage.userSnapshot, isNull);
  });
}
