import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/auth_storage.dart';
import '../services/trip_cache.dart';
import 'api_client_provider.dart';

final authServiceProvider = Provider<AuthService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AuthService(
      baseUrl: apiClient.baseUrl, httpClient: apiClient.httpClient);
});

final authStorageProvider = Provider<AuthStorage>((ref) => AuthStorage());

/// Whether the backend has Google sign-in configured (specs/google-sso).
/// Resolves false on any error, which just hides the button.
final googleSsoAvailableProvider = FutureProvider<bool>((ref) {
  return ref.watch(authServiceProvider).googleSignInAvailable();
});

/// Whether the backend has Apple sign-in configured (specs/apple-sso).
final appleSsoAvailableProvider = FutureProvider<bool>((ref) {
  return ref.watch(authServiceProvider).appleSignInAvailable();
});

class AuthState {
  final UserModel? user;
  final bool initialized; // false until the stored token has been checked
  final bool loading; // an auth request is in flight

  /// The raw failure from the last auth attempt. Deliberately an [Object?]:
  /// providers have no BuildContext, so the auth screen renders it through
  /// `friendlyError(l10n, error)` — storing a prebuilt sentence here would
  /// freeze it in whatever language was active when the request failed.
  final Object? error;

  const AuthState({
    this.user,
    this.initialized = false,
    this.loading = false,
    this.error,
  });

  bool get isSignedIn => user != null;

  AuthState copyWith({
    UserModel? user,
    bool? initialized,
    bool? loading,
    Object? error,
    bool clearUser = false,
    bool clearError = false,
  }) {
    return AuthState(
      user: clearUser ? null : (user ?? this.user),
      initialized: initialized ?? this.initialized,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  /// How long the startup session restore may block the splash screen.
  @visibleForTesting
  static Duration restoreTimeout = const Duration(seconds: 8);

  final AuthService _service;
  final AuthStorage _storage;
  final ApiClient _apiClient;

  AuthNotifier(this._service, this._storage, this._apiClient)
      : super(const AuthState()) {
    _restore();
  }

  /// On startup, restore the session from a stored token if one exists.
  ///
  /// Warm boots (token + cached user snapshot) are **optimistic**: the shell
  /// mounts immediately on the snapshot while `/auth/me` revalidates in the
  /// background (see [_revalidate] for the revalidate-on-boot semantics).
  /// First-ever boots (no snapshot yet) keep the serial check-then-mount
  /// path so a never-verified token can't flash the shell.
  Future<void> _restore() async {
    final token = await _storage.loadToken();
    if (token == null) {
      state = state.copyWith(initialized: true);
      return;
    }
    final cached = await _loadUserSnapshot();
    if (cached != null) {
      _apiClient.authToken = token;
      state = state.copyWith(user: cached, initialized: true);
      unawaited(_revalidate(token));
      return;
    }
    try {
      final user = await _service.me(token).timeout(restoreTimeout);
      _apiClient.authToken = token;
      unawaited(_saveUserSnapshot(user));
      state = state.copyWith(user: user, initialized: true);
    } on TimeoutException {
      // Backend slow/unreachable — fail open as signed out, but KEEP the
      // stored token so the next launch retries the restore.
      _apiClient.authToken = null;
      state = state.copyWith(initialized: true, clearUser: true);
    } catch (_) {
      // Token invalid/expired — clear it and start signed out.
      await _storage.clearToken();
      unawaited(_clearUserSnapshot());
      _apiClient.authToken = null;
      state = state.copyWith(initialized: true, clearUser: true);
    }
  }

  /// Background `/auth/me` check behind an optimistic warm boot
  /// (revalidate-on-boot):
  /// - success → refresh the in-memory user and the stored snapshot;
  /// - auth rejection (401/403 — the token was revoked/expired server-side)
  ///   → clear the stored session and flip to signed out;
  /// - timeout / network error / server 5xx → KEEP the optimistic state.
  ///   A valid cached session with a briefly unreachable backend beats the
  ///   old behavior of bouncing the user to the landing screen; the next
  ///   boot revalidates again.
  Future<void> _revalidate(String token) async {
    try {
      final user = await _service.me(token).timeout(restoreTimeout);
      unawaited(_saveUserSnapshot(user));
      if (!mounted) return;
      state = state.copyWith(user: user);
    } on AuthException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        await _storage.clearToken();
        unawaited(_clearUserSnapshot());
        _apiClient.authToken = null;
        if (mounted) state = state.copyWith(clearUser: true);
      }
      // Other statuses (5xx etc.): keep the optimistic session.
    } catch (_) {
      // Timeout or transport failure: keep the optimistic session.
    }
  }

  /// Decodes the cached user snapshot; null (→ serial restore path) when
  /// absent, unreadable, or corrupt. Best-effort by design: snapshot
  /// failures must never break boot.
  Future<UserModel?> _loadUserSnapshot() async {
    try {
      final raw = await _storage.loadUserSnapshot();
      if (raw == null) return null;
      return UserModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Persists the freshest server-provided user for the next warm boot.
  /// Best-effort by design, so callers fire-and-forget it (`unawaited`):
  /// a user-visible state transition must never block on — or hang with —
  /// snapshot persistence; a failure only costs the next boot its warm path.
  Future<void> _saveUserSnapshot(UserModel user) async {
    try {
      await _storage.saveUserSnapshot(jsonEncode(user.toJson()));
    } catch (_) {/* best effort */}
  }

  Future<void> _clearUserSnapshot() async {
    try {
      await _storage.clearUserSnapshot();
    } catch (_) {/* best effort */}
  }

  Future<bool> login(String email, String password) =>
      _authenticate(() => _service.login(email, password));

  Future<bool> register(String email, String password, {String? displayName}) =>
      _authenticate(
          () => _service.register(email, password, displayName: displayName));

  Future<bool> _authenticate(Future<AuthResponse> Function() call) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final res = await call();
      await _storage.saveToken(res.token);
      unawaited(_saveUserSnapshot(res.user));
      _apiClient.authToken = res.token;
      state = state.copyWith(user: res.user, loading: false);
      return true;
    } catch (e) {
      // Stored raw; the screen localizes it via friendlyError at render time
      // (an AuthException classifies by status, anything else goes generic).
      state = state.copyWith(loading: false, error: e);
      return false;
    }
  }

  /// Clears a stale failure message — e.g. when the form flips between
  /// sign-in and sign-up, where the old error no longer applies.
  void clearError() => state = state.copyWith(clearError: true);

  /// Marks onboarding done (quiz finished or skipped). On failure, unlocks
  /// locally anyway so the user is never trapped in the quiz — it simply
  /// reappears next session because the flag was never persisted.
  Future<void> completeOnboarding() async {
    try {
      final token = await _storage.loadToken();
      if (token != null) {
        final user = await _service.completeOnboarding(token);
        unawaited(_saveUserSnapshot(user));
        state = state.copyWith(user: user);
        return;
      }
    } catch (_) {/* fall through to local unlock */}
    final u = state.user;
    if (u != null) {
      state = state.copyWith(
        user: UserModel(
          id: u.id,
          email: u.email,
          displayName: u.displayName,
          isAdmin: u.isAdmin,
          needsOnboarding: false,
          createdAt: u.createdAt,
        ),
      );
    }
  }

  Future<void> logout() async {
    final token = await _storage.loadToken();
    if (token != null) {
      try {
        await _service.logout(token);
      } catch (_) {/* best effort */}
    }
    await signOutLocally();
  }

  /// Clears local auth state without calling the server — for flows where
  /// the session is already gone server-side (logout-all, account deletion).
  Future<void> signOutLocally() async {
    final userId = state.user?.id;
    await _storage.clearToken();
    unawaited(_clearUserSnapshot());
    _apiClient.authToken = null;
    state = state.copyWith(clearUser: true, clearError: true);
    // Privacy: drop the offline trip cache alongside the credentials so the
    // next user of this device can't read the previous user's plans.
    if (userId != null) await TripCache.clearForUser(userId);
  }

  /// Replaces the in-memory user (e.g. after a profile edit).
  void setUser(UserModel user) {
    state = state.copyWith(user: user);
    unawaited(_saveUserSnapshot(user)); // keep the warm-boot snapshot fresh
  }

  /// Adopts a fresh session minted by the server (e.g. after a password
  /// change revoked every other session).
  Future<void> adoptSession(String token, UserModel user) async {
    await _storage.saveToken(token);
    unawaited(_saveUserSnapshot(user));
    _apiClient.authToken = token;
    state = state.copyWith(user: user, clearError: true);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    ref.watch(authServiceProvider),
    ref.watch(authStorageProvider),
    ref.watch(apiClientProvider),
  );
});
