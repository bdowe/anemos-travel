import 'dart:convert';
import '../models/user.dart';
import 'api_client.dart';

/// Account self-service endpoints (PATCH/DELETE /auth/account,
/// change-password, logout-all).
class AccountApiService {
  final ApiClient apiClient;

  AccountApiService(this.apiClient);

  String _message(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['message'] is String) {
        return decoded['message'] as String;
      }
    } catch (_) {}
    return 'Request failed ($status)';
  }

  Future<UserModel> updateDisplayName(String displayName) async {
    final res = await apiClient.httpClient.patch(
      Uri.parse('${apiClient.baseUrl}/auth/account'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'display_name': displayName}),
    );
    if (res.statusCode == 200) {
      return UserModel.fromJson(jsonDecode(res.body));
    }
    throw Exception(_message(res.body, res.statusCode));
  }

  /// Syncs the effective UI language to the account, so server-generated text
  /// that has no request to negotiate from — above all the background emails —
  /// is written in the user's language (specs/i18n-spanish).
  Future<UserModel> updateLocale(String locale) async {
    final res = await apiClient.httpClient.patch(
      Uri.parse('${apiClient.baseUrl}/auth/account'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'locale': locale}),
    );
    if (res.statusCode == 200) {
      return UserModel.fromJson(jsonDecode(res.body));
    }
    throw Exception(_message(res.body, res.statusCode));
  }

  /// Returns the fresh session token minted after the change (every other
  /// session is revoked server-side).
  Future<({UserModel user, String token})> changePassword(
      String current, String newPassword) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/auth/change-password'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({
        'current_password': current,
        'new_password': newPassword,
      }),
    );
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (
        user: UserModel.fromJson(body['user'] as Map<String, dynamic>),
        token: body['token'] as String,
      );
    }
    throw Exception(_message(res.body, res.statusCode));
  }

  /// Updates email preferences (opt-INs: true = receiving). Pass only the
  /// stream(s) you're changing; returns the refreshed user.
  Future<UserModel> updateEmailPreferences({
    bool? remindersEnabled,
    bool? nudgesEnabled,
  }) async {
    final body = <String, dynamic>{};
    if (remindersEnabled != null) body['reminders_enabled'] = remindersEnabled;
    if (nudgesEnabled != null) body['nudges_enabled'] = nudgesEnabled;
    final res = await apiClient.httpClient.patch(
      Uri.parse('${apiClient.baseUrl}/auth/email-preferences'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode(body),
    );
    if (res.statusCode == 200) {
      return UserModel.fromJson(jsonDecode(res.body));
    }
    throw Exception(_message(res.body, res.statusCode));
  }

  Future<void> logoutAll() async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/auth/logout-all'),
      headers: apiClient.jsonHeaders(json: true),
    );
    if (res.statusCode != 204) {
      throw Exception(_message(res.body, res.statusCode));
    }
  }

  Future<void> deleteAccount(String password) async {
    final res = await apiClient.httpClient.delete(
      Uri.parse('${apiClient.baseUrl}/auth/account'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'password': password}),
    );
    if (res.statusCode != 204) {
      throw Exception(_message(res.body, res.statusCode));
    }
  }
  /// AI connectors (ChatGPT, claude.ai) this account has authorized
  /// (specs/mcp-connector).
  Future<List<ConnectedApp>> listConnectedApps() async {
    final res = await apiClient.httpClient.get(
      Uri.parse('${apiClient.baseUrl}/oauth/connections'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list
          .map((e) => ConnectedApp.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception(_message(res.body, res.statusCode));
  }

  /// Revokes a connection: the grant and every token minted under it die, so
  /// the connector stops working immediately.
  Future<void> revokeConnectedApp(String id) async {
    final res = await apiClient.httpClient.delete(
      Uri.parse('${apiClient.baseUrl}/oauth/connections/$id'),
      headers: apiClient.jsonHeaders(json: true),
    );
    if (res.statusCode != 204) {
      throw Exception(_message(res.body, res.statusCode));
    }
  }
}

/// One authorized AI connector.
class ConnectedApp {
  final String id;
  final String clientName;
  final List<String> scopes;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  const ConnectedApp({
    required this.id,
    required this.clientName,
    required this.scopes,
    required this.createdAt,
    this.lastUsedAt,
  });

  factory ConnectedApp.fromJson(Map<String, dynamic> json) => ConnectedApp(
        id: json['id'] as String,
        clientName: (json['client_name'] as String?) ?? '',
        scopes:
            ((json['scopes'] as List?) ?? const []).whereType<String>().toList(),
        createdAt: DateTime.parse(json['created_at'] as String),
        lastUsedAt: json['last_used_at'] == null
            ? null
            : DateTime.parse(json['last_used_at'] as String),
      );
}
