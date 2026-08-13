import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/route_request.dart';
import '../models/route_response.dart';

class ApiClient {
  /// Default for local `flutter run` without Docker gateway.
  /// Docker stacks use `--dart-define=API_BASE_URL=/api/v1` (same-origin).
  static const String _defaultBaseUrl = 'http://localhost:8080/api/v1';
  static const Duration _timeout = Duration(seconds: 30);
  
  late final String _baseUrl;
  final http.Client _client;

  /// The current session token, attached as a bearer credential by services
  /// that need authentication (e.g. trips). Set by the auth provider.
  String? authToken;

  /// The effective UI language, sent as `Accept-Language` so server-rendered
  /// text (trip-review findings, exports) comes back in the same language the
  /// app is showing. Set by the locale provider, which owns resolution
  /// (specs/i18n-spanish).
  String localeTag = 'en';

  ApiClient({String? baseUrl, http.Client? client}) : _client = client ?? http.Client() {
    // Use provided baseUrl, or environment variable, or default
    _baseUrl = baseUrl ??
        const String.fromEnvironment('API_BASE_URL', defaultValue: _defaultBaseUrl);
  }

  // Public getters for external access
  String get baseUrl => _baseUrl;
  http.Client get httpClient => _client;

  /// Standard request headers for the JSON API: `Accept` and `Accept-Language`
  /// always, a JSON `Content-Type` when the request carries a body ([json] is
  /// true), and the bearer token whenever a session exists. Shared by the
  /// feature services so each one doesn't re-implement its own copy.
  Map<String, String> jsonHeaders({bool json = false}) {
    final h = <String, String>{
      'Accept': 'application/json',
      'Accept-Language': localeTag,
    };
    if (json) h['Content-Type'] = 'application/json';
    final token = authToken;
    if (token != null) h['Authorization'] = 'Bearer $token';
    return h;
  }

  /// One shared request path for boot-critical JSON calls: a per-attempt
  /// [timeout] plus a small bounded retry, so one transient hiccup (a
  /// rate-limit 429, a load-shed 503, a dropped keepalive connection) doesn't
  /// become a dead screen or a session-pinned provider error.
  ///
  /// Retry rules, explicit by design:
  /// - **429/503 retry for any method**: this API emits them only from the
  ///   rate limiter and the concurrency shedder, both of which reject BEFORE
  ///   the handler runs, so the request provably had no effect. If a handler
  ///   ever emits its own 429/503, revisit this rule.
  /// - **502 and transport failures** ([http.ClientException],
  ///   [TimeoutException]) **retry GETs only** — whether the handler ran is
  ///   unknowable.
  /// - Any other status fails immediately (no retry).
  /// Delays honor `Retry-After` clamped to 4s, else 500ms·2ⁿ plus jitter.
  ///
  /// Exhausted attempts: HTTP failures throw [ApiException] with the status;
  /// transport failures rethrow the ORIGINAL exception unwrapped — callers
  /// like `TripCache.isNetworkError` classify on the concrete type.
  Future<http.Response> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? jsonBody,
    Duration timeout = const Duration(seconds: 12),
    int attempts = 3,
  }) async {
    var uri = Uri.parse('$_baseUrl$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    final headers = jsonHeaders(json: jsonBody != null);
    final body = jsonBody == null ? null : jsonEncode(jsonBody);

    http.Response? res;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final lastAttempt = attempt == attempts - 1;
      try {
        res = await _issue(method, uri, headers, body).timeout(timeout);
      } on Exception catch (e) {
        final transport = e is http.ClientException || e is TimeoutException;
        if (!transport || lastAttempt || method != 'GET') rethrow;
        await Future<void>.delayed(_retryDelay(attempt, null));
        continue;
      }
      final code = res.statusCode;
      if (code >= 200 && code < 300) return res;
      final retryable =
          code == 429 || code == 503 || (code == 502 && method == 'GET');
      if (!retryable || lastAttempt) break;
      await Future<void>.delayed(
          _retryDelay(attempt, res.headers['retry-after']));
    }
    final failed = res!;
    final snippet = failed.body.length > 200
        ? failed.body.substring(0, 200)
        : failed.body;
    throw ApiException(
      statusCode: failed.statusCode,
      message: 'Request failed: $snippet',
      endpoint: path,
    );
  }

  Future<http.Response> _issue(
      String method, Uri uri, Map<String, String> headers, String? body) {
    switch (method) {
      case 'GET':
        return _client.get(uri, headers: headers);
      case 'POST':
        return _client.post(uri, headers: headers, body: body);
      case 'PUT':
        return _client.put(uri, headers: headers, body: body);
      case 'PATCH':
        return _client.patch(uri, headers: headers, body: body);
      case 'DELETE':
        return _client.delete(uri, headers: headers, body: body);
      default:
        throw ArgumentError.value(method, 'method', 'unsupported HTTP method');
    }
  }

  static final Random _retryJitter = Random();

  Duration _retryDelay(int attempt, String? retryAfterHeader) {
    // Retry-After (seconds form) is authoritative but clamped: the UI cannot
    // hang multiple seconds on a value meant for background clients.
    final ra = int.tryParse(retryAfterHeader ?? '');
    if (ra != null) return Duration(seconds: ra.clamp(0, 4));
    return Duration(
        milliseconds: 500 * (1 << attempt) + _retryJitter.nextInt(250));
  }

  /// Optimize a route for locations
  Future<RouteResponse> optimizeRoute(RouteRequest request) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$_baseUrl/optimize-route'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(request.toJson()),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        try {
          final Map<String, dynamic> jsonData = jsonDecode(response.body);
          return RouteResponse.fromJson(jsonData);
        } catch (e) {
          throw ApiException(
            statusCode: 0,
            message: 'Failed to parse route response: $e',
            endpoint: 'optimize-route',
          );
        }
      } else {
        throw ApiException(
          statusCode: response.statusCode,
          message: 'Failed to optimize route: ${response.body}',
          endpoint: 'optimize-route',
        );
      }
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(
        statusCode: 0,
        message: 'Network error: ${e.toString()}',
        endpoint: 'optimize-route',
      );
    }
  }

  /// Check API health
  Future<Map<String, dynamic>> checkHealth() async {
    try {
      final response = await _client
          .get(
            Uri.parse('$_baseUrl/health'),
            headers: {
              'Accept': 'application/json',
            },
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw ApiException(
          statusCode: response.statusCode,
          message: 'Health check failed: ${response.body}',
          endpoint: 'health',
        );
      }
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(
        statusCode: 0,
        message: 'Network error: ${e.toString()}',
        endpoint: 'health',
      );
    }
  }

  /// Close the HTTP client
  void close() {
    _client.close();
  }
}

/// Custom exception for API errors
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final String endpoint;

  const ApiException({
    required this.statusCode,
    required this.message,
    required this.endpoint,
  });

  @override
  String toString() {
    return 'ApiException(statusCode: $statusCode, message: $message, endpoint: $endpoint)';
  }

  /// User-friendly error message
  String get userFriendlyMessage {
    switch (statusCode) {
      case 0:
        return 'Please check your internet connection and try again.';
      case 400:
        return 'Invalid request. Please check your input and try again.';
      case 404:
        return 'Service not found. Please try again later.';
      case 500:
        return 'Server error. Please try again later.';
      case 503:
        return 'Service temporarily unavailable. Please try again later.';
      default:
        return 'An unexpected error occurred. Please try again.';
    }
  }

  /// Whether this is a network-related error
  bool get isNetworkError => statusCode == 0;

  /// Whether this is a client error (4xx)
  bool get isClientError => statusCode >= 400 && statusCode < 500;

  /// Whether this is a server error (5xx)
  bool get isServerError => statusCode >= 500;
}

/// True when [e] describes a transient condition worth an automatic retry or
/// self-heal: a transport-level failure, or an HTTP status this API emits
/// only for temporary states (rate limit 429, shed 503, gateway 502/504).
/// Stable outcomes (401/403/404/422…) never match — retrying them can only
/// mask a real bug or resurrect revoked data.
bool isTransientError(Object e) =>
    e is http.ClientException ||
    e is TimeoutException ||
    (e is ApiException &&
        (e.statusCode == 0 ||
            e.statusCode == 429 ||
            e.statusCode == 502 ||
            e.statusCode == 503 ||
            e.statusCode == 504));
