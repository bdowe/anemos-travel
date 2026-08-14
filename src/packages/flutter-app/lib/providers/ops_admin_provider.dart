import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ops_health.dart';
import '../models/ops_metrics.dart';
import '../models/ops_uptime.dart';
import '../services/ops_admin_api_service.dart';
import 'api_client_provider.dart';

final opsAdminApiServiceProvider = Provider<OpsAdminApiService>((ref) {
  return OpsAdminApiService(ref.watch(apiClientProvider));
});

/// Live process + request metrics. Instantaneous — the Health pane invalidates
/// it on a timer to auto-refresh.
final opsMetricsProvider = FutureProvider<OpsMetrics>((ref) async {
  return ref.watch(opsAdminApiServiceProvider).getOpsMetrics();
});

/// Dependency + build + backup health. Auto-refreshed alongside
/// [opsMetricsProvider].
final opsHealthProvider = FutureProvider<OpsHealth>((ref) async {
  return ref.watch(opsAdminApiServiceProvider).getOpsHealth();
});

/// 90-day availability history for the Health pane's status strip.
///
/// Deliberately NOT on the pane's 10s timer: the server buckets whole days
/// from samples minutes apart, so a 10s re-poll would re-scan 90 days ~30x
/// per useful change and buy nothing. Refreshes on pull-to-refresh and on
/// app resume only.
final opsUptimeProvider = FutureProvider<OpsUptime>((ref) async {
  return ref.watch(opsAdminApiServiceProvider).getOpsUptime();
});
