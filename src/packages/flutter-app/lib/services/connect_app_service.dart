import 'dart:convert';

import 'api_client.dart';

/// What a pending connector authorization is asking for — rendered by the
/// consent screen (specs/mcp-connector). `clientName` is self-asserted by the
/// registering app, which is why the screen labels it unverified.
class ConnectAppRequest {
  final String clientName;
  final List<String> scopes;

  const ConnectAppRequest({required this.clientName, required this.scopes});

  factory ConnectAppRequest.fromJson(Map<String, dynamic> json) =>
      ConnectAppRequest(
        clientName: (json['client_name'] as String?) ?? '',
        scopes:
            ((json['scopes'] as List?) ?? const []).whereType<String>().toList(),
      );
}

/// Raised when the request token is expired, already used, or unknown — the
/// user has to start over from their AI assistant.
class ConnectAppExpired implements Exception {
  const ConnectAppExpired();
}

/// Raised when the decision call has no usable session behind it. Distinct
/// from a generic failure on purpose: "you are signed out" has a cure (sign
/// in and come back), so the screen routes there instead of showing an error
/// the user can only stare at.
class ConnectAppUnauthorized implements Exception {
  const ConnectAppUnauthorized();
}

/// Talks to the OAuth consent endpoints. The request token itself is the
/// credential for [fetchRequest] (the screen must render before sign-in);
/// [decide] is authenticated and binds the grant to the signed-in user.
class ConnectAppService {
  final ApiClient apiClient;

  ConnectAppService(this.apiClient);

  Future<ConnectAppRequest> fetchRequest(String requestToken) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/oauth/authorize/context'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'request_token': requestToken}),
    );
    if (res.statusCode == 200) {
      return ConnectAppRequest.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
    }
    if (res.statusCode == 410 || res.statusCode == 400) {
      throw const ConnectAppExpired();
    }
    throw Exception('Could not load authorization request (${res.statusCode})');
  }

  /// Approves or denies; returns the URL to send the browser back to (it
  /// carries either the authorization code or `error=access_denied`).
  Future<String> decide(String requestToken, {required bool approve}) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/oauth/authorize/decision'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'request_token': requestToken, 'approve': approve}),
    );
    if (res.statusCode == 200) {
      return (jsonDecode(res.body) as Map<String, dynamic>)['redirect_url']
          as String;
    }
    if (res.statusCode == 410) {
      throw const ConnectAppExpired();
    }
    // authMiddleware answers 401 for a missing, revoked, or expired session.
    if (res.statusCode == 401) {
      throw const ConnectAppUnauthorized();
    }
    throw Exception('Could not complete authorization (${res.statusCode})');
  }
}
