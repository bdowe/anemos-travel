import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/ops_health.dart';
import '../models/ops_metrics.dart';
import '../models/ops_uptime.dart';
import '../providers/ops_admin_provider.dart';
import '../theme/app_typography.dart';
import '../theme/spacing.dart';
import 'empty_state.dart';
import 'page_container.dart';
import 'section_header.dart';
import 'status_pill.dart';
import 'uptime_strip.dart';

/// The "Health" tab of the admin dashboard: a live snapshot of the API
/// process, request mix, dependency health, and backup freshness. Auto-refreshes
/// every 10s (paused while the app is backgrounded) and supports pull-to-refresh.
class HealthPane extends ConsumerStatefulWidget {
  const HealthPane({super.key});

  @override
  ConsumerState<HealthPane> createState() => _HealthPaneState();
}

class _HealthPaneState extends ConsumerState<HealthPane>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  static const _refreshInterval = Duration(seconds: 10);
  Timer? _timer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  /// The 10s tick — instantaneous data ONLY. The 90-day uptime history is
  /// deliberately not here: it changes at most every few minutes server-side,
  /// so re-polling it every 10s would buy nothing (see opsUptimeProvider).
  void _refresh() {
    if (!mounted) return;
    ref.invalidate(opsMetricsProvider);
    ref.invalidate(opsHealthProvider);
  }

  /// Everything, including the uptime history — for the two events where a
  /// stale history is plausible: returning from the background, and an
  /// explicit pull-to-refresh.
  void _refreshAll() {
    if (!mounted) return;
    _refresh();
    ref.invalidate(opsUptimeProvider);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause polling in the background; resume (and refresh once) on return.
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      _refreshAll();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = context.l10n;
    final metrics = ref.watch(opsMetricsProvider);
    final health = ref.watch(opsHealthProvider);
    final uptime = ref.watch(opsUptimeProvider);

    return PageContainer(
      child: RefreshIndicator(
        onRefresh: () async {
          _refreshAll();
          await Future.wait([
            ref.read(opsMetricsProvider.future),
            ref.read(opsHealthProvider.future),
            ref.read(opsUptimeProvider.future),
          ]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // The uptime history leads: it answers the pane's headline
            // question ("has this been up?"), and it is the one block that is
            // stable under the 10s refresh of everything below it.
            uptime.when(
              loading: () => const _UptimeSkeleton(),
              error: (e, _) => EmptyState(
                icon: Icons.cloud_off,
                title: l10n.healthUptimeErrorTitle,
                message: '$e',
                actions: [
                  FilledButton(
                    onPressed: () => ref.invalidate(opsUptimeProvider),
                    child: Text(l10n.commonRetry),
                  ),
                ],
              ),
              data: (u) => _UptimeSection(uptime: u),
            ),
            const SizedBox(height: AppSpacing.xl),
            metrics.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => EmptyState(
                icon: Icons.cloud_off,
                title: l10n.healthMetricsErrorTitle,
                message: '$e',
                actions: [
                  FilledButton(
                    onPressed: () => ref.invalidate(opsMetricsProvider),
                    child: Text(l10n.commonRetry),
                  ),
                ],
              ),
              data: (m) => _MetricsSection(metrics: m),
            ),
            const SizedBox(height: AppSpacing.xl),
            health.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => EmptyState(
                icon: Icons.cloud_off,
                title: l10n.healthHealthErrorTitle,
                message: '$e',
                actions: [
                  FilledButton(
                    onPressed: () => ref.invalidate(opsHealthProvider),
                    child: Text(l10n.commonRetry),
                  ),
                ],
              ),
              data: (h) => _HealthSection(health: h),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}

// --- Uptime history (specs/uptime-history) -----------------------------------

/// The 90-day status strip section: one [UptimeStrip] per monitored component,
/// led by a one-line honesty note — this is the API's self-check, which by
/// construction cannot observe a gateway/tunnel/edge outage.
class _UptimeSection extends StatelessWidget {
  final OpsUptime uptime;
  const _UptimeSection({required this.uptime});

  /// Component key → localized display name. Keys are the wire contract
  /// (ops_uptime.go uptimeComponentKeys); an unknown key renders verbatim
  /// rather than dropping the row.
  static String _componentLabel(AppLocalizations l10n, String key) =>
      switch (key) {
        'api' => l10n.healthUptimeComponentApi,
        'database' => l10n.healthDatabase,
        'ai_provider' => l10n.healthUptimeComponentAi,
        'backups' => l10n.healthBackupsSection,
        _ => key,
      };

  /// Status pill: up=green, down=red, no_data=neutral — the strip's status is
  /// an instant (never "degraded"), see UptimeComponent.status.
  static StatusPill _statusPill(
      ThemeData theme, AppLocalizations l10n, String status) {
    switch (status) {
      case 'up':
        return _pill(theme, l10n.healthPillOk, 'ok');
      case 'down':
        return _pill(theme, l10n.healthUptimePillDown, 'critical');
      default:
        return _pill(theme, l10n.healthPillUnknown, 'neutral');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    if (uptime.components.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: l10n.healthUptimeSection),
        const SizedBox(height: AppSpacing.xs),
        // The honesty label: self-observed, blind to edge/gateway outages.
        Text(
          l10n.healthUptimeSelfCheckNote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        for (final c in uptime.components) ...[
          UptimeStrip(
            label: _componentLabel(l10n, c.key),
            days: c.days,
            uptimePct: c.uptimePct,
            observedDays: c.observedDays,
            monitoringSince: uptime.monitoringSince,
            pill: _statusPill(theme, l10n, c.status),
          ),
          if (c != uptime.components.last)
            const SizedBox(height: AppSpacing.lg),
        ],
      ],
    );
  }
}

/// Loading placeholder with the section's rough final extent so the Process
/// tiles below don't jump when the data lands.
class _UptimeSkeleton extends StatelessWidget {
  const _UptimeSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: context.l10n.healthUptimeSection),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < 4; i++) ...[
          Container(
            height: kMinTouchTarget,
            margin: const EdgeInsets.only(bottom: AppSpacing.lg),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: AppRadius.mdAll,
            ),
          ),
        ],
      ],
    );
  }
}

// --- KPI tiles ---------------------------------------------------------------

/// Uptime + request-mix headline tiles.
class _MetricsSection extends StatelessWidget {
  final OpsMetrics metrics;
  const _MetricsSection({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final m = metrics;
    final errRate = m.requests.errorRate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: l10n.healthProcessSection),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(tiles: [
          _Stat(l10n.healthProcessUptime, _formatUptime(m.process.uptimeS)),
          _Stat(l10n.healthRequests, _compact(m.requests.total),
              caption: _classCaption(m.requests.byClass)),
          _Stat(l10n.healthErrorRate, '${(errRate * 100).toStringAsFixed(1)}%',
              severity: _errSeverity(errRate)),
          _Stat(l10n.healthGoroutines, '${m.process.goroutines}',
              caption: 'GOMAXPROCS ${m.process.gomaxprocs}'),
          _Stat(l10n.healthMemory, '${_mb(m.process.memAllocBytes)} MB',
              caption: '${_mb(m.process.memSysBytes)} MB sys'),
          if (m.upstream.placesUpstreamCalls > 0 ||
              m.upstream.placesCacheHits > 0)
            _Stat(l10n.healthPlacesCalls, '${m.upstream.placesUpstreamCalls}',
                caption: l10n.healthCacheHits(m.upstream.placesCacheHits)),
        ]),
        if (m.requests.routes.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          SectionHeader(title: l10n.healthRoutesSection),
          const SizedBox(height: AppSpacing.sm),
          _RouteTable(routes: m.requests.routes),
        ],
      ],
    );
  }

  static String _classCaption(Map<String, int> byClass) {
    final ok = byClass['2xx'] ?? 0;
    final c4 = byClass['4xx'] ?? 0;
    final c5 = byClass['5xx'] ?? 0;
    return '$ok 2xx · $c4 4xx · $c5 5xx';
  }

  static String? _errSeverity(double rate) {
    if (rate >= 0.05) return 'critical';
    if (rate >= 0.02) return 'warn';
    return null;
  }
}

/// Top routes by count. Horizontally scrollable so wide rows never overflow.
class _RouteTable extends StatelessWidget {
  final List<RouteMetric> routes;
  const _RouteTable({required this.routes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final sorted = [...routes]..sort((a, b) => b.count.compareTo(a.count));
    final top = sorted.take(12).toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: AppSpacing.xl,
        headingRowHeight: 36,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 44,
        columns: [
          DataColumn(label: Text(l10n.healthColRoute)),
          DataColumn(label: Text(l10n.healthColMethod)),
          DataColumn(label: Text(l10n.healthColCount), numeric: true),
          DataColumn(label: Text(l10n.healthColErrorPct), numeric: true),
          const DataColumn(label: Text('p95 ms'), numeric: true),
        ],
        rows: [
          for (final r in top)
            DataRow(cells: [
              DataCell(ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(r.route, overflow: TextOverflow.ellipsis),
              )),
              DataCell(Text(r.method)),
              DataCell(Text('${r.count}')),
              DataCell(Text(
                '${(r.errorRate * 100).toStringAsFixed(1)}%',
                style: r.errorRate >= 0.05
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              )),
              DataCell(Text(r.p95Ms.toStringAsFixed(0))),
            ]),
        ],
      ),
    );
  }
}

// --- Dependencies + backups --------------------------------------------------

class _HealthSection extends StatelessWidget {
  final OpsHealth health;
  const _HealthSection({required this.health});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final h = health;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (h.degraded) ...[
          _DegradedBanner(reasons: h.reasons),
          const SizedBox(height: AppSpacing.lg),
        ],
        SectionHeader(title: l10n.healthDependenciesSection),
        const SizedBox(height: AppSpacing.sm),
        _DependencyRow(
          label: l10n.healthDatabase,
          detail: h.db.status == 'ok' ? l10n.healthPing(h.db.pingMs) : null,
          pill: _dbPill(theme, l10n, h.db),
        ),
        for (final p in h.providers)
          _DependencyRow(
            label: _humanize(p.name),
            detail: p.note.isEmpty ? null : p.note,
            pill: p.configured
                ? _pill(theme, l10n.healthPillConfigured, 'ok')
                : _pill(theme, l10n.healthPillNotConfigured, 'warn'),
          ),
        const SizedBox(height: AppSpacing.xl),
        SectionHeader(title: l10n.healthBackupsSection),
        const SizedBox(height: AppSpacing.sm),
        _DependencyRow(
          label: l10n.healthLastBackup,
          detail: h.backups.ageS != null
              ? l10n.healthBackupAge(_humanizeAge(h.backups.ageS!))
              : l10n.healthNoBackupRecorded,
          pill: _backupPill(theme, l10n, h.backups),
        ),
        if (h.build.release.isNotEmpty || h.build.goVersion.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          SectionHeader(title: l10n.healthBuildSection),
          const SizedBox(height: AppSpacing.sm),
          Text(
            [
              if (h.build.release.isNotEmpty)
                l10n.healthRelease(h.build.release),
              if (h.build.goVersion.isNotEmpty) h.build.goVersion,
            ].join(' · '),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  // db.status / backup state are canonical API values — only their pill
  // labels are translated (specs/i18n-spanish).
  static Widget _dbPill(ThemeData theme, AppLocalizations l10n, HealthDb db) {
    switch (db.status) {
      case 'ok':
        return _pill(theme, l10n.healthPillOk, 'ok');
      case 'unreachable':
        return _pill(theme, l10n.healthPillUnreachable, 'critical');
      default:
        return _pill(theme, l10n.healthPillNotConfigured, 'warn');
    }
  }

  static Widget _backupPill(
      ThemeData theme, AppLocalizations l10n, BackupInfo b) {
    if (b.ageS == null) return _pill(theme, l10n.healthPillUnknown, 'warn');
    if (b.stale) return _pill(theme, l10n.healthPillStale, 'critical');
    return _pill(theme, l10n.healthPillFresh, 'ok');
  }
}

class _DegradedBanner extends StatelessWidget {
  final List<String> reasons;
  const _DegradedBanner({required this.reasons});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: AppRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 20, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: AppSpacing.sm),
              Text(
                context.l10n.healthDegradedTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            for (final r in reasons)
              Text(
                '• $r',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _DependencyRow extends StatelessWidget {
  final String label;
  final String? detail;
  final Widget pill;
  const _DependencyRow({required this.label, this.detail, required this.pill});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                if (detail != null)
                  Text(
                    detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          pill,
        ],
      ),
    );
  }
}

// --- Shared helpers ----------------------------------------------------------

/// Severity → pill. ok=green, warn=amber, critical=red (mirrors the Trip
/// Health severity palette).
StatusPill _pill(ThemeData theme, String label, String severity) {
  final (bg, fg) = _severityColors(theme, severity);
  return StatusPill.custom(label: label, background: bg, foreground: fg);
}

(Color, Color) _severityColors(ThemeData theme, String severity) {
  switch (severity) {
    case 'critical':
      return (theme.colorScheme.errorContainer, theme.colorScheme.onErrorContainer);
    case 'warn':
      return (Colors.amber.withValues(alpha: 0.20), Colors.amber.shade900);
    case 'ok':
      return (Colors.green.withValues(alpha: 0.15), Colors.green.shade800);
    default:
      return (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      );
  }
}

String _formatUptime(int seconds) {
  if (seconds <= 0) return '0s';
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '${seconds}s';
}

/// Seconds → coarse "3d" / "4h" / "5m" / "30s" for the backup age line.
String _humanizeAge(int seconds) {
  if (seconds >= 86400) return '${seconds ~/ 86400}d';
  if (seconds >= 3600) return '${seconds ~/ 3600}h';
  if (seconds >= 60) return '${seconds ~/ 60}m';
  return '${seconds}s';
}

String _compact(int v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '$v';
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

/// "google_places" → "Google places".
String _humanize(String name) {
  final s = name.replaceAll('_', ' ');
  return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

// --- Tile primitives (mirrors admin_metrics_screen's _Stat/_TileGrid) --------

class _Stat {
  final String label;
  final String value;
  final String? caption;

  /// Optional severity that tints the value (warn=amber, critical=red).
  final String? severity;
  const _Stat(this.label, this.value, {this.caption, this.severity});
}

class _TileGrid extends StatelessWidget {
  final List<_Stat> tiles;
  const _TileGrid({required this.tiles});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.md,
      children: [
        for (final t in tiles)
          Container(
            constraints: const BoxConstraints(minWidth: 140),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: AppRadius.mdAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  t.value,
                  // A measurement, not a heading — stays in the UI face
                  // (see the same opt-out in admin_metrics_screen.dart).
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontFamily: AppFonts.ui,
                    fontWeight: FontWeight.w700,
                    color: t.severity == 'critical'
                        ? theme.colorScheme.error
                        : t.severity == 'warn'
                            ? Colors.amber.shade900
                            : null,
                  ),
                ),
                if (t.caption != null)
                  Text(
                    t.caption!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
