import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the connector consent request across a sign-in round trip
/// (specs/mcp-connector).
///
/// Why this has to survive device storage rather than live in a field: Google
/// and Apple sign-in navigate the whole page away from /connect/<token>
/// (`webOnlyWindowName: '_self'`) and come back at /sso/<code>, so every scrap
/// of in-memory state is gone by the time there is a session. Without this the
/// browser lands on the app shell and the pending authorization is silently
/// abandoned — the user believes they approved, while the server never
/// received a decision (observed in production 2026-08-14).
class PendingConnectStore {
  static const _tokenKey = 'pending_connect.request_token';
  static const _savedAtKey = 'pending_connect.saved_at';

  /// Longer than the server's 10-minute request lifetime, so a user who is
  /// mid-sign-in is never bounced past a request that is still good; short
  /// enough that a token forgotten here can't capture an unrelated sign-in
  /// days later. A stale one costs nothing anyway — the consent screen shows
  /// the expired state and the user starts over from their AI assistant.
  static const maxAge = Duration(minutes: 15);

  const PendingConnectStore();

  /// Every method swallows storage failures. Device storage can be
  /// unavailable (private browsing, a full quota), and this is a convenience:
  /// losing the reminder costs the user one more click, whereas an exception
  /// here would strand them on the SSO landing screen mid-sign-in.

  /// Records that [requestToken] is waiting on a session. Call immediately
  /// before handing off to sign-in.
  Future<void> save(String requestToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, requestToken);
      await prefs.setInt(
          _savedAtKey, DateTime.now().toUtc().millisecondsSinceEpoch);
    } catch (_) {
      // Best effort — see the note above.
    }
  }

  /// Returns the pending request token and forgets it — single use, so a
  /// completed or abandoned link can never replay on a later sign-in. Null
  /// when nothing is pending or the record aged out.
  Future<String?> take() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
      final savedAt = prefs.getInt(_savedAtKey);
      await clear();
      if (token == null || token.isEmpty || savedAt == null) return null;
      final age = DateTime.now().toUtc().millisecondsSinceEpoch - savedAt;
      if (age < 0 || age > maxAge.inMilliseconds) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      await prefs.remove(_savedAtKey);
    } catch (_) {
      // Best effort — see the note above.
    }
  }
}
