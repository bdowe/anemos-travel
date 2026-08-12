import 'dart:convert';
import '../models/notification.dart';
import 'api_client.dart';

/// Client for the generalized notifications feed (Wave 16): `/notifications`,
/// `/notifications/read`, `/notifications/unread-count`.
class NotificationsApiService {
  final ApiClient apiClient;

  NotificationsApiService(this.apiClient);

  String _errorMessage(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['message'] is String) {
        return decoded['message'] as String;
      }
    } catch (_) {}
    return 'Request failed ($status)';
  }

  /// The notification feed, newest-first.
  Future<List<AppNotification>> list({int limit = 50}) async {
    final res = await apiClient.httpClient.get(
      Uri.parse('${apiClient.baseUrl}/notifications?limit=$limit'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception(_errorMessage(res.body, res.statusCode));
  }

  /// Marks all of the caller's notifications read (the mark-all read model —
  /// opening the center is the read action). Idempotent; returns 204.
  Future<void> markRead() async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/notifications/read'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode != 204) {
      throw Exception(_errorMessage(res.body, res.statusCode));
    }
  }

  /// The unread badge number.
  Future<int> unreadCount() async {
    final res = await apiClient.httpClient.get(
      Uri.parse('${apiClient.baseUrl}/notifications/unread-count'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) {
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      return (decoded['count'] as num?)?.toInt() ?? 0;
    }
    throw Exception(_errorMessage(res.body, res.statusCode));
  }
}
