import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the session token on-device so the user stays signed in across
/// app restarts. Backed by Keychain/Keystore on mobile and an encrypted
/// store on web.
///
/// Alongside the token it caches the last server-provided user JSON
/// (specs: optimistic shell boot) so a warm boot can mount the shell
/// immediately from the snapshot while `/auth/me` revalidates in the
/// background. The snapshot lives and dies with the token: both are written
/// on sign-in and cleared together on sign-out/revocation.
class AuthStorage {
  static const _tokenKey = 'session_token';
  static const _userKey = 'session_user';
  final FlutterSecureStorage _storage;

  AuthStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<String?> loadToken() => _storage.read(key: _tokenKey);

  Future<void> clearToken() => _storage.delete(key: _tokenKey);

  /// Caches the last successful auth user payload (encoded JSON).
  Future<void> saveUserSnapshot(String userJson) =>
      _storage.write(key: _userKey, value: userJson);

  Future<String?> loadUserSnapshot() => _storage.read(key: _userKey);

  Future<void> clearUserSnapshot() => _storage.delete(key: _userKey);
}
