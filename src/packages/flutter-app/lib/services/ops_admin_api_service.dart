import 'dart:convert';
import '../models/ops_health.dart';
import '../models/ops_metrics.dart';
import '../models/ops_uptime.dart';
import 'api_client.dart';

/// GET /admin/ops/{metrics,health,uptime} — live process/request metrics,
/// dependency/backup health, and the 90-day uptime history for the System
/// Health dashboard tab. All require an admin bearer token (enforced
/// server-side by adminMiddleware).
class OpsAdminApiService {
  final ApiClient apiClient;

  OpsAdminApiService(this.apiClient);

  /// The window the Health pane's status strip renders. A constant, not a
  /// picker: "last 90 days" is the status-page artifact. If a selector ever
  /// lands, this becomes the provider's family key.
  static const int uptimeWindowDays = 90;

  Future<T> _get<T>(String pathAndQuery, T Function(dynamic) parse) async {
    final res = await apiClient.httpClient.get(
      Uri.parse('${apiClient.baseUrl}$pathAndQuery'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) {
      return parse(jsonDecode(res.body));
    }
    throw Exception('Failed to load $pathAndQuery (${res.statusCode})');
  }

  Future<OpsMetrics> getOpsMetrics() =>
      _get('/admin/ops/metrics', (json) => OpsMetrics.fromJson(json));

  Future<OpsHealth> getOpsHealth() =>
      _get('/admin/ops/health', (json) => OpsHealth.fromJson(json));

  Future<OpsUptime> getOpsUptime({int days = uptimeWindowDays}) =>
      _get('/admin/ops/uptime?days=$days', (json) => OpsUptime.fromJson(json));
}
