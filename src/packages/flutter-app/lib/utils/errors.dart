import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

/// Maps a caught error to a short, localized, user-facing message so raw
/// [ApiException] dumps never reach a snackbar or error banner.
///
/// - An [ApiException] is classified by HTTP status: network (statusCode 0),
///   an expired/forbidden session (401/403), rate limiting (429), a server
///   fault (5xx), or a generic fallback for everything else.
/// - An [AuthException] is classified the same way, except 401 means the
///   credentials were wrong (the user isn't signed in yet, so "session
///   expired" would be nonsense) and 409 means the email already has an
///   account.
/// - A plain [String] is assumed to already be user-facing — e.g. a friendly
///   error the `/plan` SSE stream sent — and is returned unchanged.
/// - Anything else falls back to the generic message; the raw object is never
///   surfaced to the user.
String friendlyError(AppLocalizations l10n, Object? error) {
  if (error is String) return error;
  if (error is ApiException) {
    switch (error.statusCode) {
      case 0:
        return l10n.errorNetwork;
      case 401:
      case 403:
        return l10n.errorSession;
      case 429:
        return l10n.errorTooManyRequests;
    }
    if (error.statusCode >= 500) return l10n.errorServer;
    return l10n.errorGeneric;
  }
  if (error is AuthException) {
    switch (error.statusCode) {
      case 401:
        return l10n.authErrorInvalidCredentials;
      case 409:
        return l10n.authErrorEmailTaken;
      case 429:
        return l10n.errorTooManyRequests;
    }
    if (error.statusCode >= 500) return l10n.errorServer;
    return l10n.errorGeneric;
  }
  // A socket-level failure never got an HTTP status: offline, DNS, CORS.
  if (error is http.ClientException) return l10n.errorNetwork;
  return l10n.errorGeneric;
}
