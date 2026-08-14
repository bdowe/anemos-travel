import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/admin_insights.dart';
import '../models/admin_metrics.dart';
import '../providers/admin_metrics_provider.dart';
import '../theme/spacing.dart';
import '../widgets/daily_count_chart.dart';
import '../widgets/empty_state.dart';
import '../widgets/health_pane.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../widgets/status_pill.dart';

/// Growth analytics dashboard (admin-only; the API enforces adminMiddleware).
/// Four tabs:
///   Overview — all-time totals off the domain tables + the windowed Phase-1
///              funnel stat tiles from docs/business-model.md §8.
///   Trends   — daily bar charts (small multiples) for the funnel events.
///   Activity — the latest analytics events, newest first, load-more.
///   Users    — per-user activity aggregates, most recently active first.
class AdminMetricsScreen extends ConsumerStatefulWidget {
  /// Index of the Health tab in the tab list below. Named so callers in other
  /// files (the ops rows in the notification center) never carry a bare
  /// literal — the tab order stays defined in exactly one place.
  static const int healthTabIndex = 4;

  /// Which tab to open on. Transient view state, deliberately NOT part of the
  /// URL: `/admin/metrics` stays one location, so a refresh lands on Overview.
  final int initialTabIndex;

  const AdminMetricsScreen({super.key, this.initialTabIndex = 0});

  @override
  ConsumerState<AdminMetricsScreen> createState() => _AdminMetricsScreenState();
}

class _AdminMetricsScreenState extends ConsumerState<AdminMetricsScreen> {
  // Shared by Overview and Trends so switching tabs keeps the same window.
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      initialIndex: widget.initialTabIndex,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Metrics'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Trends'),
              Tab(text: 'Activity'),
              Tab(text: 'Users'),
              Tab(text: 'Health'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _OverviewPane(
              days: _days,
              onDaysChanged: (d) => setState(() => _days = d),
            ),
            _TrendsPane(
              days: _days,
              onDaysChanged: (d) => setState(() => _days = d),
            ),
            const _ActivityPane(),
            const _UsersPane(),
            const HealthPane(),
          ],
        ),
      ),
    );
  }
}

/// The 7/30/90-day window selector shared by Overview and Trends.
class _DaysSelector extends StatelessWidget {
  final int days;
  final ValueChanged<int> onChanged;
  const _DaysSelector({required this.days, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 7, label: Text('7 days')),
          ButtonSegment(value: 30, label: Text('30 days')),
          ButtonSegment(value: 90, label: Text('90 days')),
        ],
        selected: {days},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

class _OverviewPane extends ConsumerWidget {
  final int days;
  final ValueChanged<int> onDaysChanged;
  const _OverviewPane({required this.days, required this.onDaysChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(adminMetricsProvider(days));

    return PageContainer(
      child: Column(
        children: [
          _DaysSelector(days: days, onChanged: onDaysChanged),
          Expanded(
            child: metrics.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: Icons.cloud_off,
                title: 'Could not load metrics',
                message: '$e',
                actions: [
                  FilledButton(
                    onPressed: () => ref.invalidate(adminMetricsProvider(days)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
              // Pull-to-refresh re-polls both async sources this pane shows,
              // matching the Activity/Users panes' affordance.
              data: (m) => RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(adminTotalsProvider);
                  ref.invalidate(adminMetricsProvider(days));
                  await ref.read(adminMetricsProvider(days).future);
                },
                child: _MetricsBody(metrics: m, header: _TotalsSection()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// All-time counts off the domain tables — rides at the top of Overview's
/// scroll with its own async lifecycle (a totals failure never blanks the
/// windowed metrics below it).
class _TotalsSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final totals = ref.watch(adminTotalsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'All-time totals'),
        const SizedBox(height: AppSpacing.sm),
        totals.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Row(
            children: [
              Expanded(
                child: Text(
                  'Could not load totals',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => ref.invalidate(adminTotalsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
          data: (t) => _TileGrid(tiles: [
            _Stat('Users', '${t.users}',
                caption:
                    '${t.verifiedUsers} verified · ${t.onboardedUsers} onboarded'),
            _Stat('Trips', '${t.trips}', caption: '${t.tripLineages} lineages'),
            _Stat('Itinerary items', '${t.itineraryItems}'),
            _Stat('Booking todos', '${t.bookingTodos}'),
            _Stat('Published local recs', '${t.publishedLocalRecs}',
                caption: '${t.localGuides} guides'),
            _Stat('Sharing', '${t.activeShares}',
                caption: '${t.activeCollaborators} collaborators'),
            _Stat('Active sessions', '${t.activeSessions}'),
            _Stat('Analytics events', '${t.analyticsEvents}'),
          ]),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

/// The Trends tab: one [DailyCountChart] small-multiple per funnel event.
class _TrendsPane extends ConsumerWidget {
  final int days;
  final ValueChanged<int> onDaysChanged;
  const _TrendsPane({required this.days, required this.onDaysChanged});

  // Series key → chart title, top-of-funnel to bottom (matches the API's
  // timeseriesEventTypes; unknown keys in the payload are simply not shown).
  static const _series = [
    ('landing_viewed', 'Landing views'),
    ('user_registered', 'Signups'),
    ('trip_created', 'Trips created'),
    ('plan_session_started', 'Plan sessions'),
    ('booking_link_clicked', 'Booking clicks'),
    ('itinerary_item_added', 'Itinerary items added'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = ref.watch(adminTimeseriesProvider(days));

    return PageContainer(
      child: Column(
        children: [
          _DaysSelector(days: days, onChanged: onDaysChanged),
          Expanded(
            child: ts.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: Icons.cloud_off,
                title: 'Could not load trends',
                message: '$e',
                actions: [
                  FilledButton(
                    onPressed: () =>
                        ref.invalidate(adminTimeseriesProvider(days)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
              // Pull-to-refresh, matching the Activity/Users panes.
              data: (t) => RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(adminTimeseriesProvider(days));
                  await ref.read(adminTimeseriesProvider(days).future);
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    for (final (key, title) in _series) ...[
                      DailyCountChart(title: title, data: t.denseSeries(key)),
                      const SizedBox(height: AppSpacing.xl),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricsBody extends StatelessWidget {
  final AdminMetrics metrics;

  /// Optional widget above the windowed sections (Overview's all-time
  /// totals) — inside this ListView so the whole pane scrolls as one.
  final Widget? header;
  const _MetricsBody({required this.metrics, this.header});

  String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

  String _tokens(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }

  String _usd(double v) => '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    return ListView(
      // Always scrollable so Overview's pull-to-refresh works even when the
      // tiles fit the viewport.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (header != null) header!,
        const SectionHeader(title: 'Funnel'),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(tiles: [
          // Hidden (not zero) when the API predates landing_views — null
          // means "old API", 0 means "no views".
          if (m.landingViews != null)
            _Stat('Landing views', '${m.landingViews}',
                caption: 'directional — anonymous, rate-limit bounded'),
          _Stat('Signups', '${m.signups}'),
          _Stat('Activated', '${m.activatedSignups}',
              caption: _pct(m.activationRate)),
          _Stat('Onboardings', '${m.onboardingsCompleted}'),
          _Stat('Second-trip retention', '${m.secondTripRetention}',
              caption: '≥2 trips ≥7 days apart'),
          _Stat('Multi-day planners', '${m.sessionFrequencyReturning}',
              caption: 'sessions on ≥2 days'),
        ]),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader(title: 'Trips & bookings'),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(tiles: [
          _Stat('Trips created', '${m.tripsCreated}'),
          _Stat('Trips refined', '${m.tripsRefined}'),
          _Stat('Attach rate', _pct(m.attachRate),
              caption: '${m.tripsWithBookingClick} trips w/ click'),
          // The anonymous share (signed-out clicks, rate-limit bounded but
          // unaudited) rides as a caption so partner-facing reads can
          // discount it; caption absent on APIs that predate the split.
          _Stat('Booking clicks', '${m.bookingClicks}',
              caption: m.bookingClicksAnonymous != null
                  ? '${m.bookingClicksAnonymous} anonymous'
                  : null),
          _Stat('Marked booked', '${m.todosMarkedBooked}'),
        ]),
        if (m.clicksByProvider.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          _ProviderClicks(clicks: m.clicksByProvider),
        ],
        // Anonymous slice of the provider split (signed-out clicks — same
        // discountable caveat as the caption above). Hidden when null (API
        // predates the split) or empty, so old backends render unchanged.
        if (m.clicksByProviderAnonymous?.isNotEmpty ?? false) ...[
          const SizedBox(height: AppSpacing.lg),
          _ProviderClicks(
            clicks: m.clicksByProviderAnonymous!,
            title: 'Anonymous clicks by provider',
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader(title: 'AI planning'),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(tiles: [
          _Stat('Active users (MAU)', '${m.activeUsers}'),
          _Stat('Est. cost / active user', _usd(m.estCogsPerActiveUser),
              caption: 'Claude only, estimate'),
          _Stat('Plan sessions', '${m.planSessions}',
              caption: '${m.planSessionsAnonymous} anonymous'),
          _Stat('Agent loop cap hits', '${m.agentLoopCapHits}',
              caption: 'runaway-loop signal'),
          _Stat('Would hit plan cap', '${m.freeCapWouldHits['plan_runs'] ?? 0}',
              caption:
                  '${m.freeCapUsersAffected['plan_runs'] ?? 0} users affected'),
          _Stat('Would hit trip cap',
              '${m.freeCapWouldHits['active_trips'] ?? 0}',
              caption:
                  '${m.freeCapUsersAffected['active_trips'] ?? 0} users affected'),
          _Stat('Tokens in', _tokens(m.planInputTokens),
              caption: '${_tokens(m.planCacheReadTokens)} from cache'),
          _Stat('Tokens out', _tokens(m.planOutputTokens),
              caption: 'est. ${_usd(m.estClaudeCostUsd)} total'),
        ]),
        if (m.placesCallsSinceProcessStart != null ||
            m.eventsCallsSinceProcessStart != null) ...[
          const SizedBox(height: AppSpacing.xl),
          // Deliberately labeled "(since restart)": these counters are
          // process-lifetime on the API and reset on every deploy — they are
          // NOT scoped to the selected window above.
          const SectionHeader(title: 'Provider APIs (since restart)'),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Process-lifetime counters — reset on API restart, '
            'not scoped to the selected window.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _TileGrid(tiles: [
            if (m.placesCallsSinceProcessStart != null) ...[
              _Stat(
                'Places API (since restart)',
                '${m.placesCallsSinceProcessStart!.totalUpstream}',
                caption:
                    '${m.placesCallsSinceProcessStart!.totalCacheHits} cache hits'
                    ' · est. ${_usd(m.placesCallsSinceProcessStart!.estPlacesCostUsd)}',
              ),
              _Stat(
                'Places by class',
                '${m.placesCallsSinceProcessStart!.search.upstream} search',
                caption:
                    '${m.placesCallsSinceProcessStart!.autocomplete.upstream} autocomplete'
                    ' · ${m.placesCallsSinceProcessStart!.details.upstream} details',
              ),
            ],
            if (m.eventsCallsSinceProcessStart != null)
              _Stat(
                'Events API (since restart)',
                '${m.eventsCallsSinceProcessStart!.upstream}',
                caption:
                    '${m.eventsCallsSinceProcessStart!.cacheHits} cache hits · free tier',
              ),
          ]),
        ],
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }
}

class _Stat {
  final String label;
  final String value;
  final String? caption;
  const _Stat(this.label, this.value, {this.caption});
}

/// Responsive tile row: fixed-min-width tiles that wrap. Values wear text
/// tokens (never a series color) per the dataviz rules — these are headline
/// numbers, not encoded marks.
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
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
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

/// Booking clicks by provider: labeled rows with a single-hue proportional
/// bar. One hue on purpose — the bars encode magnitude, the labels carry
/// identity, so no categorical palette is needed.
class _ProviderClicks extends StatelessWidget {
  final Map<String, int> clicks;
  final String title;
  const _ProviderClicks(
      {required this.clicks, this.title = 'Clicks by provider'});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = clicks.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final max = entries.first.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.labelLarge),
        const SizedBox(height: AppSpacing.sm),
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    e.key,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 10,
                        width: max == 0
                            ? 0
                            : constraints.maxWidth * (e.value / max),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${e.value}',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// --- Activity ----------------------------------------------------------------

String _relTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// "booking_link_clicked" → "Booking link clicked".
String _humanize(String eventType) {
  final s = eventType.replaceAll('_', ' ');
  return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

/// The latest analytics events, newest first. First page via
/// [adminActivityProvider]; older pages are fetched imperatively with the
/// keyset cursor and appended locally. Keep-alive so paging survives tab
/// switches; pull-to-refresh resets to the newest page.
class _ActivityPane extends ConsumerStatefulWidget {
  const _ActivityPane();
  @override
  ConsumerState<_ActivityPane> createState() => _ActivityPaneState();
}

class _ActivityPaneState extends ConsumerState<_ActivityPane>
    with AutomaticKeepAliveClientMixin {
  final List<AdminActivityEvent> _older = [];
  String? _olderCursor; // non-null once _older extends the first page
  bool _loadingMore = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _loadMore(String cursor) async {
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(adminMetricsApiServiceProvider)
          .fetchActivity(before: cursor);
      if (!mounted) return;
      setState(() {
        _older.addAll(page.events);
        _olderCursor = page.nextBefore;
      });
    } catch (_) {
      // Leave the cursor as-is so the button retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final feed = ref.watch(adminActivityProvider);

    return PageContainer(
      child: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: 'Could not load activity',
          message: '$e',
          actions: [
            FilledButton(
              onPressed: () => ref.invalidate(adminActivityProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
        data: (first) {
          final events = [...first.events, ..._older];
          if (events.isEmpty) {
            return const EmptyState(
              icon: Icons.timeline,
              title: 'No activity yet',
              message: 'Events show up here as people use the app.',
            );
          }
          // _olderCursor is set the moment paging starts; before that the
          // first page's cursor drives the button.
          final cursor = _older.isEmpty ? first.nextBefore : _olderCursor;
          return RefreshIndicator(
            onRefresh: () async {
              setState(() {
                _older.clear();
                _olderCursor = null;
              });
              ref.invalidate(adminActivityProvider);
              await ref.read(adminActivityProvider.future);
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              itemCount: events.length + (cursor != null ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == events.length) {
                  return Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Center(
                      child: _loadingMore
                          ? const CircularProgressIndicator()
                          : OutlinedButton(
                              onPressed: () => _loadMore(cursor!),
                              child: const Text('Load more'),
                            ),
                    ),
                  );
                }
                return _ActivityTile(event: events[i]);
              },
            ),
          );
        },
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  final AdminActivityEvent event;
  const _ActivityTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final who = event.userEmail ?? 'anonymous';
    final meta = event.metadata;
    // Surface the two metadata keys that identify what was acted on.
    final detail = [
      if (meta?['provider'] != null) '${meta!['provider']}',
      if (meta?['source'] != null) '${meta!['source']}',
    ].join(' · ');

    return ListTile(
      dense: true,
      title: Text(_humanize(event.eventType)),
      subtitle: Text(detail.isEmpty ? who : '$who · $detail'),
      leading: event.userEmail == null
          ? Icon(Icons.person_off_outlined,
              size: 20, color: theme.colorScheme.onSurfaceVariant)
          : Icon(Icons.person_outline,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
      trailing: Text(
        _relTime(event.createdAt),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// --- Users ---------------------------------------------------------------

/// Per-user drill-down: most recently active first, expandable rows, offset
/// paging. Keep-alive for the same reason as the Activity pane.
class _UsersPane extends ConsumerStatefulWidget {
  const _UsersPane();
  @override
  ConsumerState<_UsersPane> createState() => _UsersPaneState();
}

class _UsersPaneState extends ConsumerState<_UsersPane>
    with AutomaticKeepAliveClientMixin {
  final List<AdminUserRow> _more = [];
  bool _loadingMore = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _loadMore(int offset) async {
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(adminMetricsApiServiceProvider)
          .fetchUsers(offset: offset);
      if (!mounted) return;
      setState(() => _more.addAll(page.users));
    } catch (_) {
      // Button stays; tapping retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final list = ref.watch(adminUsersProvider(0));

    return PageContainer(
      child: list.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: 'Could not load users',
          message: '$e',
          actions: [
            FilledButton(
              onPressed: () => ref.invalidate(adminUsersProvider(0)),
              child: const Text('Retry'),
            ),
          ],
        ),
        data: (first) {
          final users = [...first.users, ..._more];
          final hasMore = users.length < first.total;
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _more.clear());
              ref.invalidate(adminUsersProvider(0));
              await ref.read(adminUsersProvider(0).future);
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              itemCount: users.length + (hasMore ? 1 : 0) + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.xs,
                    ),
                    child: Text(
                      '${first.total} users',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  );
                }
                if (i == users.length + 1) {
                  return Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Center(
                      child: _loadingMore
                          ? const CircularProgressIndicator()
                          : OutlinedButton(
                              onPressed: () => _loadMore(users.length),
                              child: const Text('Load more'),
                            ),
                    ),
                  );
                }
                return _UserTile(user: users[i - 1]);
              },
            ),
          );
        },
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  final AdminUserRow user;
  const _UserTile({required this.user});

  String _tokens(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      title: Row(
        children: [
          Flexible(
            child: Text(user.email, overflow: TextOverflow.ellipsis),
          ),
          if (user.isAdmin) ...[
            const SizedBox(width: AppSpacing.sm),
            StatusPill.custom(
              label: 'admin',
              background: theme.colorScheme.tertiaryContainer,
              foreground: theme.colorScheme.onTertiaryContainer,
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${user.trips} trips · ${user.lastEventAt != null ? 'active ${_relTime(user.lastEventAt!)}' : 'no activity'}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.sm,
          children: [
            _kv(theme, 'Trip lineages', '${user.tripLineages}'),
            _kv(theme, 'Plan sessions', '${user.planSessions}'),
            _kv(theme, 'Booking clicks', '${user.bookingClicks}'),
            _kv(theme, 'Tokens in / out',
                '${_tokens(user.planInputTokens)} / ${_tokens(user.planOutputTokens)}'),
            _kv(theme, 'Est. Claude cost',
                '\$${user.estClaudeCostUsd.toStringAsFixed(2)}'),
            _kv(theme, 'Signed up',
                '${user.signedUpAt.year}-${user.signedUpAt.month.toString().padLeft(2, '0')}-${user.signedUpAt.day.toString().padLeft(2, '0')}'),
            _kv(theme, 'Onboarded', user.onboarded ? 'yes' : 'no'),
            _kv(theme, 'Email verified', user.emailVerified ? 'yes' : 'no'),
          ],
        ),
      ],
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        Text(value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}
