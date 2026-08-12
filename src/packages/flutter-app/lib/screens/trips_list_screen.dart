import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../theme/spacing.dart';
import '../utils/trip_format.dart';
import '../utils/trip_list_order.dart';
import '../widgets/account_menu.dart';
import '../widgets/collapsible_section.dart';
import '../widgets/continue_chats_section.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/live_trip_card.dart';
import '../widgets/offline_banner.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../widgets/status_pill.dart';
import '../models/chat_session.dart';
import '../models/trip.dart';
import '../providers/auth_provider.dart';
import '../providers/live_trip_provider.dart';
import '../providers/resumable_chats_provider.dart';
import '../providers/shared_with_me_provider.dart';
import '../providers/trips_provider.dart';
import 'import_trip_screen.dart';
import 'trip_detail_screen.dart';

class TripsListScreen extends ConsumerStatefulWidget {
  const TripsListScreen({super.key});

  @override
  ConsumerState<TripsListScreen> createState() => _TripsListScreenState();
}

class _TripsListScreenState extends ConsumerState<TripsListScreen> {
  /// "Past trips" starts collapsed; kept in screen state (the
  /// [CollapsibleSection] contract) so it survives silent refreshes and the
  /// offline-banner reparent.
  bool _pastExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tripsProvider.notifier).loadTrips();
      // Boot dedup: this screen mounts at shell boot (IndexedStack keeps all
      // tabs alive), when HomeScreen's very first resumable-chats fetch is
      // still in flight — invalidating then would throw that request away and
      // issue a duplicate /chats call. Skip the refresh while a fetch is
      // already loading; on later remounts the provider has data (or an
      // error) and the refresh proceeds as before.
      if (!ref.read(resumableChatsProvider).isLoading) {
        ref.invalidate(resumableChatsProvider);
      }
      ref.invalidate(sharedWithMeProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final state = ref.watch(tripsProvider);
    final resumable = ref.watch(resumableChatsProvider).valueOrNull ??
        const <ChatSessionSummary>[];
    // Watched before the guard branches: an account whose only trips are
    // shared-with-me must reach the list, not the plan-a-trip empty state.
    // (The saved-trip graduation listen lives inside ContinueChatsSection —
    // no duplicate listener here.)
    final sharedAsync = ref.watch(sharedWithMeProvider);
    final shared = sharedAsync.valueOrNull ?? const <Trip>[];

    Widget body;
    if ((state.loading || sharedAsync.isLoading) &&
        state.trips.isEmpty &&
        resumable.isEmpty &&
        shared.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (state.error != null &&
        state.trips.isEmpty &&
        resumable.isEmpty &&
        shared.isEmpty) {
      body = EmptyState(
        icon: Icons.cloud_off,
        title: l10n.tripsListErrorTitle,
        message: l10n.tripsListErrorMessage,
        iconColor: theme.colorScheme.error.withValues(alpha: 0.6),
        actions: [
          FilledButton(
            onPressed: () => ref.read(tripsProvider.notifier).loadTrips(),
            child: Text(l10n.commonRetry),
          ),
        ],
      );
    } else if (state.trips.isEmpty && resumable.isEmpty && shared.isEmpty) {
      body = EmptyState(
        icon: Icons.luggage,
        title: l10n.tripsListEmptyTitle,
        message: l10n.tripsListEmptyMessage,
        actions: [
          FilledButton.icon(
            onPressed: () =>
                ref.read(navIndexProvider.notifier).state = AppTab.plan.index,
            icon: const Icon(Icons.auto_awesome),
            label: Text(l10n.tripsListPlanTrip),
          ),
          // Planned elsewhere (ChatGPT/Claude)? Paste it in instead
          // (specs/import-trip-from-ai-chat).
          OutlinedButton.icon(
            onPressed: () => _openImport(context),
            icon: const Icon(Icons.content_paste_go, size: 18),
            label: Text(l10n.importFromAi),
          ),
        ],
      );
    } else {
      final isAdmin = ref.watch(authProvider).user?.isAdmin ?? false;
      final liveTrip = ref.watch(liveTripProvider);
      // Server order is newest-created-first; the list shows travel-date
      // order instead — next trip on top, finished trips tucked into a
      // collapsed group (utils/trip_list_order.dart). The live trip is
      // exempt from the past group so its Live pill never hides in there.
      final now = DateTime.now();
      final groups =
          partitionTripsForList(state.trips, now, liveTripId: liveTrip?.id);
      // Same ordering for shared-with-me, but no collapse: the section is
      // short, and a header-inside-a-header would read as clutter. Past
      // shared trips simply sort last.
      final sharedGroups = partitionTripsForList(shared, now);
      final sharedOrdered = [...sharedGroups.upcoming, ...sharedGroups.past];
      body = RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(sharedWithMeProvider);
          ref.invalidate(resumableChatsProvider);
          await ref.read(tripsProvider.notifier).loadTrips();
        },
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          // Pull-to-refresh must arm even when the list is shorter than the
          // viewport (one or two trips is the common case) — clamping physics
          // would swallow the gesture on Android/web.
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            // Centered 700px column on wide layouts, Home's exact pattern:
            // the ListView stays full-width (wheel/scrollbar work in the
            // gutters) while the content is capped. Non-lazy is fine at
            // trips-list sizes, same trade Home makes.
            PageContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The trip happening today, promoted to the very top as a
                  // one-tap shortcut (specs/happening-now). It also stays in
                  // "My Trips" below — this is a spotlight, not a filter.
                  if (liveTrip != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      child: LiveTripCard(
                        trip: liveTrip,
                        onTap: () => _openTrip(context, liveTrip.id),
                      ),
                    ),
                  // In-progress AI conversations that haven't produced a
                  // trip yet (specs/continue-where-you-left-off) — the
                  // discussion phase, above the trips they may become. Same
                  // shared section as Home; it collapses to nothing when
                  // empty and already ends in an AppSpacing.lg gap, so the
                  // My Trips header below needs no top padding of its own.
                  const ContinueChatsSection(),
                  if (resumable.isNotEmpty && state.trips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs, 0, 0, AppSpacing.sm),
                      child: SectionHeader(title: l10n.tripsListTitle),
                    ),
                  for (final t in groups.upcoming)
                    _TripCard(trip: t, isAdmin: isAdmin),
                  if (groups.past.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: CollapsibleSection(
                        title: l10n.tripsListPastTrips,
                        icon: Icons.history,
                        pill: StatusPill.custom(
                          label: l10n
                              .tripsListPastTripsCount(groups.past.length),
                          background:
                              theme.colorScheme.surfaceContainerHighest,
                          foreground: theme.colorScheme.onSurfaceVariant,
                        ),
                        expanded: _pastExpanded,
                        onToggle: () =>
                            setState(() => _pastExpanded = !_pastExpanded),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final t in groups.past)
                              _TripCard(trip: t, isAdmin: isAdmin),
                          ],
                        ),
                      ),
                    ),
                  // Trips others invited this user to co-plan. Kept as a
                  // separate section: "mine" vs "shared with me" is the
                  // mental model, and the card shows the owner instead of
                  // admin version chrome.
                  if (sharedOrdered.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs, AppSpacing.lg, 0, AppSpacing.sm),
                      child: SectionHeader(title: l10n.tripsListSharedWithYou),
                    ),
                    for (final t in sharedOrdered)
                      _TripCard(trip: t, isAdmin: false),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Offline: the list is a cached copy — pin the banner above it so the
    // staleness (and the way back online) is always visible.
    final offlineSince = state.offlineSince;
    if (offlineSince != null) {
      body = Column(
        children: [
          OfflineBanner(
            savedAt: offlineSince,
            onRetry: () => ref.read(tripsProvider.notifier).loadTrips(),
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: GradientAppBar(
        title: Text(l10n.tripsListTitle),
        actions: [
          IconButton(
            tooltip: l10n.importFromAi,
            icon: const Icon(Icons.content_paste_go),
            onPressed: () => _openImport(context),
          ),
          const AccountMenu(),
        ],
      ),
      body: body,
    );
  }
}

void _openTrip(BuildContext context, String tripId) {
  Navigator.of(context).push(
    locatedRoute(TripDetailScreen(tripId: tripId), tripDetailLocation(tripId)),
  );
}

void _openImport(BuildContext context) {
  Navigator.of(context).push(
    locatedRoute(
        const ImportTripScreen(), utilityLocation(BootUtility.importTrip)),
  );
}

/// A single trip in the list. Shows the latest version of its chat; for admins,
/// when the chat produced multiple versions it expands to list the older ones.
class _TripCard extends ConsumerWidget {
  final Trip trip;
  final bool isAdmin;

  const _TripCard({required this.trip, required this.isAdmin});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final versions = trip.versionCount ?? 1;
    final hasHistory = isAdmin && versions > 1 && trip.chatId != null;
    final range = tripDateRange(trip.startDate, trip.endDate);

    final cities = citiesLabel(
      trip.cities,
      two: (a, b) => l10n.citiesTwo(a, b),
      more: (a, b, n) => l10n.citiesMore(a, b, n),
    );
    // Same rule as the trip-detail header (_displayTitle): the trip's own
    // title unless it's really the AI summary, then the cities label. The
    // cities line below is only shown when it isn't already the headline.
    final usableTitle = trip.title.isNotEmpty && !tripTitleIsLong(trip.title);
    final headline = usableTitle ? trip.title : (cities ?? trip.title);
    final showCitiesLine = cities != null && headline != cities;

    final title = Text(
      headline,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    );

    final subtitle = Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (range != null)
                _DateChip(label: range)
              else
                Text(l10n.tripsListCreated(shortDate(trip.createdAt))),
              if (!trip.isOwner && (trip.ownerName ?? '').isNotEmpty)
                Text(
                  trip.canEdit
                      ? l10n.tripsListPlannedWith(trip.ownerName!)
                      : l10n.tripsListSharedBy(trip.ownerName!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
            ],
          ),
          if (showCitiesLine)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                cities,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );

    if (!hasHistory) {
      return Card(
        child: ListTile(
          leading: Icon(trip.isOwner
              ? Icons.map_outlined
              : trip.canEdit
                  ? Icons.group_outlined
                  : Icons.visibility_outlined),
          title: title,
          subtitle: subtitle,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openTrip(context, trip.id),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.map_outlined),
        title: title,
        subtitle: Row(
          children: [
            Expanded(child: subtitle),
            _VersionBadge(count: versions),
          ],
        ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          _VersionList(chatId: trip.chatId!, latestId: trip.id),
        ],
      ),
    );
  }
}

/// Display-only date range, styled as a tonal pill so it pairs with the
/// [StatusPill] beside it and matches the trip-detail header's date chip.
class _DateChip extends StatelessWidget {
  final String label;
  const _DateChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event,
              size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  final int count;
  const _VersionBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'v$count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Admin-only: lazily loads and lists every version a chat produced.
class _VersionList extends ConsumerWidget {
  final String chatId;
  final String latestId;

  const _VersionList({required this.chatId, required this.latestId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return FutureBuilder<List<Trip>>(
      future: ref.read(tripsApiServiceProvider).listTripVersions(chatId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.tripsListVersionsError,
                style: theme.textTheme.bodySmall),
          );
        }
        final versions = snap.data ?? const [];
        return Column(
          children: [
            for (var i = 0; i < versions.length; i++)
              ListTile(
                dense: true,
                leading: const Icon(Icons.history, size: 20),
                title: Text(versions[i].title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  i == 0
                      ? l10n.tripsListVersionLatest(
                          shortDate(versions[i].createdAt))
                      : l10n.tripsListVersionNumbered(versions.length - i,
                          shortDate(versions[i].createdAt)),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openTrip(context, versions[i].id),
              ),
          ],
        );
      },
    );
  }
}
