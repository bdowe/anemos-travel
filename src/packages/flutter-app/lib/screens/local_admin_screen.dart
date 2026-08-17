import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/local_provider.dart';
import '../services/api_client.dart';
import '../theme/spacing.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../utils/snack.dart';

/// Admin-only console for curating local-sourced content. Three panes:
///   Ingest   — paste raw research text + pick a local source → AI drafts pins.
///   Review   — the draft queue; verify coordinates, publish (or see why blocked).
///   Coverage — which cities have published vs draft coverage.
/// Reached from the account menu when the signed-in user is an admin; the routes
/// it calls are also enforced admin-only server-side.
class LocalAdminScreen extends ConsumerStatefulWidget {
  const LocalAdminScreen({super.key});

  @override
  ConsumerState<LocalAdminScreen> createState() => _LocalAdminScreenState();
}

class _LocalAdminScreenState extends ConsumerState<LocalAdminScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: const GradientAppBar(
          title: 'Local intel admin',
        ),
        body: Column(
          children: const [
            Material(
              color: Colors.transparent,
              child: TabBar(
                labelColor: Colors.black87,
                tabs: [
                  Tab(text: 'Ingest', icon: Icon(Icons.auto_awesome)),
                  Tab(text: 'Review', icon: Icon(Icons.fact_check)),
                  Tab(text: 'Coverage', icon: Icon(Icons.map)),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _IngestPane(),
                  _ReviewPane(),
                  _CoveragePane(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Ingest ------------------------------------------------------------------

class _IngestPane extends ConsumerStatefulWidget {
  const _IngestPane();
  @override
  ConsumerState<_IngestPane> createState() => _IngestPaneState();
}

class _IngestPaneState extends ConsumerState<_IngestPane> {
  final _city = TextEditingController();
  final _raw = TextEditingController();
  String _kind = 'transcript';
  String? _sourceId;
  List<Map<String, dynamic>> _sources = [];
  bool _loadingSources = true;
  bool _busy = false;
  String? _result;
  String? _error;

  /// Separate from [_error] (ingest/validation failures shown under the
  /// submit button): a sources-load failure renders inline where the source
  /// dropdown would be, so it is visible on phones without scrolling.
  String? _sourcesError;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _city.dispose();
    _raw.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    setState(() {
      _loadingSources = true;
      _sourcesError = null;
    });
    try {
      final s = await ref.read(localApiServiceProvider).listSources();
      if (!mounted) return;
      setState(() {
        _sources = s;
        _sourceId ??= s.isNotEmpty ? s.first['id'] as String : null;
      });
    } catch (e) {
      if (mounted) setState(() => _sourcesError = '$e');
    } finally {
      if (mounted) setState(() => _loadingSources = false);
    }
  }

  Future<void> _newSourceDialog() async {
    final name = TextEditingController();
    final credibility = TextEditingController();
    final photo = TextEditingController();
    final consent = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New local source'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name *')),
              const SizedBox(height: AppSpacing.md),
              TextField(
                  controller: credibility,
                  decoration: const InputDecoration(
                      labelText: 'Credibility (chef, 20yr resident…)')),
              const SizedBox(height: AppSpacing.md),
              TextField(
                  controller: photo,
                  decoration: const InputDecoration(labelText: 'Photo URL')),
              const SizedBox(height: AppSpacing.md),
              TextField(
                  controller: consent,
                  decoration: const InputDecoration(
                      labelText: 'Consent reference (release/email)')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (created == true && name.text.trim().isNotEmpty) {
      try {
        final row = await ref.read(localApiServiceProvider).createSource({
          'name': name.text.trim(),
          'credibility': credibility.text.trim(),
          'photo_url': photo.text.trim(),
          'consent_ref': consent.text.trim(),
        });
        if (!mounted) return;
        setState(() => _sourceId = row['id'] as String);
        await _loadSources();
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    }
  }

  Future<void> _ingest() async {
    if (_sourceId == null ||
        _city.text.trim().isEmpty ||
        _raw.text.trim().isEmpty) {
      setState(() => _error = 'Pick a source and fill in city + raw text.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final res = await ref.read(localApiServiceProvider).ingest(
            sourceId: _sourceId!,
            city: _city.text.trim(),
            kind: _kind,
            rawText: _raw.text.trim(),
          );
      final recs = (res['recommendations'] as List?)?.length ?? 0;
      final verified = res['verified'] ?? 0;
      final unverified = res['unverified'] ?? 0;
      if (!mounted) return;
      setState(() {
        _result =
            'Drafted $recs recommendation(s): $verified verified, $unverified need coordinates.'
            '${res['guide_id'] != null ? ' A guide was drafted too.' : ''}';
        _raw.clear();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Draft recommendations from raw material',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Paste an interview transcript or notes. Claude extracts structured '
          'pins grounded only in the text, then each is verified against Google '
          'before it can be published.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_loadingSources)
          const LinearProgressIndicator()
        else if (_sourcesError != null)
          // Inline where the dropdown would be — a load failure used to hide
          // at the bottom of this ListView, off-screen on phones.
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Banner(
                icon: Icons.error_outline,
                color: theme.colorScheme.error,
                text: 'Could not load sources: $_sourcesError',
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _loadSources,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _sourceId,
                  // Constrain to the row: an unexpanded dropdown sizes to its
                  // widest item, so a long source name overflows narrow phones.
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Local source', border: OutlineInputBorder()),
                  items: _sources
                      .map((s) => DropdownMenuItem(
                            value: s['id'] as String,
                            child: Text(s['name'] as String? ?? '—'),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _sourceId = v),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton.filledTonal(
                onPressed: _newSourceDialog,
                icon: const Icon(Icons.person_add),
                tooltip: 'New source',
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _city,
                decoration: const InputDecoration(
                    labelText: 'City', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Kind', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(
                      value: 'transcript', child: Text('Transcript')),
                  DropdownMenuItem(value: 'notes', child: Text('Notes')),
                  DropdownMenuItem(
                      value: 'voice_memo', child: Text('Voice memo')),
                ],
                onChanged: (v) => setState(() => _kind = v ?? 'transcript'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _raw,
          maxLines: 10,
          decoration: const InputDecoration(
            labelText: 'Raw material',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          onPressed: _busy ? null : _ingest,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: Text(_busy ? 'Extracting…' : 'Extract drafts'),
        ),
        if (_result != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Banner(
              icon: Icons.check_circle, color: Colors.green, text: _result!),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Banner(
              icon: Icons.error_outline,
              color: theme.colorScheme.error,
              text: _error!),
        ],
      ],
    );
  }
}

// --- Review ------------------------------------------------------------------

class _ReviewPane extends ConsumerStatefulWidget {
  const _ReviewPane();
  @override
  ConsumerState<_ReviewPane> createState() => _ReviewPaneState();
}

class _ReviewPaneState extends ConsumerState<_ReviewPane> {
  List<Map<String, dynamic>> _drafts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ref.read(localApiServiceProvider).listByStatus('draft');
      if (mounted) setState(() => _drafts = d);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _publish(String id) async {
    try {
      await ref.read(localApiServiceProvider).publish(id);
      if (mounted) showSnack(context, 'Published.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _RefreshableState(
        onRefresh: _load,
        child: EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load drafts',
          message: _error!,
          actions: [
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_drafts.isEmpty) {
      return _RefreshableState(
        onRefresh: _load,
        child: const EmptyState(
          icon: Icons.inbox,
          title: 'No drafts to review',
          message: 'Ingest raw material to generate draft recommendations.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.md),
        itemCount: _drafts.length,
        itemBuilder: (_, i) {
          final d = _drafts[i];
          final verified = d['place_verified'] == true;
          final hasCoords = d['latitude'] != null && d['longitude'] != null;
          return Card(
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(d['name'] as String? ?? '—',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(verified ? 'verified' : 'unverified'),
                        backgroundColor: verified
                            ? Colors.green.withValues(alpha: 0.15)
                            : theme.colorScheme.errorContainer,
                      ),
                    ],
                  ),
                  Text(
                    [
                      d['city'],
                      d['neighborhood'],
                      d['category'],
                      d['source_name'],
                    ].where((e) => e != null && '$e'.isNotEmpty).join(' · '),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if ((d['tip'] as String?)?.isNotEmpty ?? false) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(d['tip'] as String),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      // Flexible so the hint ellipsizes instead of pushing
                      // the Publish button off a narrow card.
                      if (!hasCoords)
                        Expanded(
                          child: Text('Needs coordinates to publish',
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.error)),
                        )
                      else
                        const Spacer(),
                      const SizedBox(width: AppSpacing.sm),
                      FilledButton.tonalIcon(
                        onPressed: hasCoords
                            ? () => _publish(d['id'] as String)
                            : null,
                        icon: const Icon(Icons.publish, size: 18),
                        label: const Text('Publish'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// --- Coverage ----------------------------------------------------------------

class _CoveragePane extends ConsumerStatefulWidget {
  const _CoveragePane();
  @override
  ConsumerState<_CoveragePane> createState() => _CoveragePaneState();
}

class _CoveragePaneState extends ConsumerState<_CoveragePane> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(localApiServiceProvider).coverage();
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _RefreshableState(
        onRefresh: _load,
        child: EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load coverage',
          message: _error!,
          actions: [FilledButton(onPressed: _load, child: const Text('Retry'))],
        ),
      );
    }
    if (_rows.isEmpty) {
      return _RefreshableState(
        onRefresh: _load,
        child: const EmptyState(
          icon: Icons.map_outlined,
          title: 'No coverage yet',
          message: 'Publish recommendations to build city coverage.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          // Horizontally scrollable so long city names never overflow narrow
          // widths — the same pattern as health_pane.dart's _RouteTable.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: AppSpacing.xl,
              headingRowHeight: 36,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 44,
              columns: const [
                DataColumn(label: Text('City')),
                DataColumn(label: Text('Published'), numeric: true),
                DataColumn(label: Text('Draft'), numeric: true),
              ],
              rows: _rows
                  .map((r) => DataRow(cells: [
                        DataCell(Text(r['city'] as String? ?? '—')),
                        DataCell(Text('${r['published'] ?? 0}')),
                        DataCell(Text('${r['draft'] ?? 0}')),
                      ]))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// --- shared ------------------------------------------------------------------

/// Wraps a non-list state (error / empty) in a viewport-filling scrollable
/// inside a RefreshIndicator, so pull-to-refresh still works when there are
/// no rows to scroll — the exact case an admin hits right after ingesting.
class _RefreshableState extends StatelessWidget {
  final Future<void> Function() onRefresh;
  final Widget child;
  const _RefreshableState({required this.onRefresh, required this.child});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: constraints.maxHeight, child: child),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Banner({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
