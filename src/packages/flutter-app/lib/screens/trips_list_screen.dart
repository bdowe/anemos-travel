import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../theme/spacing.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import '../utils/trip_list_insights.dart';
import '../utils/trip_list_order.dart';
import '../widgets/account_menu.dart';
import '../widgets/collapsible_section.dart';
import '../widgets/continue_chats_section.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/live_trip_card.dart';
import '../widgets/meta_chip.dart';
import '../widgets/offline_banner.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../widgets/status_pill.dart';
import '../widgets/travel_footprint_card.dart';
import '../widgets/up_next_trip_card.dart';
import '../models/chat_session.dart';
import '../models/trip.dart';
import '../providers/auth_provider.dart';
import '../providers/live_trip_provider.dart';
import '../providers/resumable_chats_provider.dart';
import '../providers/shared_with_me_provider.dart';
import '../providers/trips_provider.dart';
import 'trip_detail_screen.dart';

/// Handles for the three "Log a past trip" entry points (specs/log-past-trip).
/// Locale-free on purpose, the kTraveledStatsKey convention: they all carry the
/// same label, so a test asking by text couldn't tell them apart — and couldn't
/// answer the question that matters, which is that every account size has at
/// least one way in.
const kLogTripSectionActionKey = ValueKey('logTrip.entry.section');
const kLogTripAppBarKey = ValueKey('logTrip.entry.appBar');
const kLogTripEmptyStateKey = ValueKey('logTrip.entry.emptyState');

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
            onPressed: () => openImportOnTripsTab(ref),
            icon: const Icon(Icons.content_paste_go, size: 18),
            label: Text(l10n.importFromAi),
          ),
          // Already travelled, just never here (specs/log-past-trip). The
          // empty state is this entry point's only home for an account with
          // no trips — "Your travels", where it otherwise lives, needs two.
          OutlinedButton.icon(
            key: kLogTripEmptyStateKey,
            onPressed: () => openLogTripOnTripsTab(ref),
            icon: const Icon(Icons.edit_calendar_outlined, size: 18),
            label: Text(l10n.logTripAction),
          ),
        ],
      );
    } else {
      final isAdmin = ref.watch(authProvider).user?.isAdmin ?? false;
      final liveTrip = ref.watch(liveTripProvider);
      // Server order is newest-created-first; the list shows travel-date
      // order instead — next trip on top, finished trips tucked into a
      // collapsed group (utils/trip_list_order.dart). The live trip is
      // exempt from the past group so the promoted trip can never be filed
      // under "Past trips"; the promotion below is what takes it out of the
      // Upcoming run.
      final now = DateTime.now();
      final groups =
          partitionTripsForList(state.trips, now, liveTripId: liveTrip?.id);
      // Same ordering for shared-with-me, but no collapse: the section is
      // short, and a header-inside-a-header would read as clutter. Past
      // shared trips simply sort last.
      final sharedGroups = partitionTripsForList(shared, now);
      final sharedOrdered = [...sharedGroups.upcoming, ...sharedGroups.past];
      // The soonest dated upcoming trip, promoted to an "Up next" hero. A
      // live trip already owns the promoted slot, so the hero yields to it —
      // one promoted object at a time.
      final hero = liveTrip == null ? upNextTrip(groups.upcoming, now) : null;
      // Whichever hero got the slot, it REPLACES its plain card: a promoted
      // trip is never listed twice, and "Upcoming" never contains a trip
      // already under way. ONE name for "the promoted trip" and one
      // subtraction from the run — the live trip used to show twice precisely
      // because there were two notions of promoted and only `hero` was
      // subtracted.
      final promotedId = liveTrip?.id ?? hero?.id;
      final upcomingCards = [
        for (final t in groups.upcoming)
          if (t.id != promotedId) t
      ];
      // "Your travels" is over OWNED trips (shared-with-me is someone else's
      // travel, and its payload carries no pins anyway), split into what's
      // been travelled and what's still planned — the band sits where the page
      // turns from plans to history, so a number that silently mixed the two
      // was reading as travel already taken. Gated at 2+: an aggregate of one
      // trip only restates the hero.
      final stats = travelStats(state.trips, now);
      final pins = footprintPins(state.trips, now);
      final showFootprint = state.trips.length >= 2;
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
                  // one-tap shortcut (specs/happening-now). It sits ABOVE the
                  // "Upcoming" header, and its plain card is gone from the
                  // run below — a trip you're on is not upcoming.
                  if (liveTrip != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      child: LiveTripCard(
                        trip: liveTrip,
                        onTap: () => _openTrip(context, ref, liveTrip.id),
                      ),
                    ),
                  // In-progress AI conversations that haven't produced a
                  // trip yet (specs/continue-where-you-left-off) — the
                  // discussion phase, above the trips they may become. Same
                  // shared section as Home; it collapses to nothing when
                  // empty and already ends in an AppSpacing.lg gap, so the
                  // My Trips header below needs no top padding of its own.
                  const ContinueChatsSection(),
                  // Always-on section header — before it existed only next to
                  // a resumable-chats section, leaving the common case with
                  // bare cards under the app bar. "Upcoming" (not the app
                  // bar's "My Trips" again) mirrors "Past trips" below, and
                  // its action is the populated list's one create affordance
                  // (the empty state keeps its own Plan-a-trip button).
                  if (state.trips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs, 0, 0, AppSpacing.sm),
                      child: SectionHeader(
                        title: l10n.tripsListUpcoming,
                        action: TextButton.icon(
                          onPressed: () => ref
                              .read(navIndexProvider.notifier)
                              .state = AppTab.plan.index,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(l10n.tripsListNewTrip),
                        ),
                      ),
                    ),
                  if (hero != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: UpNextTripCard(
                        trip: hero,
                        onTap: () => _openTrip(context, ref, hero.id),
                      ),
                    ),
                  for (final t in upcomingCards)
                    _TripCard(trip: t, isAdmin: isAdmin),
                  // "Your travels": the retrospective section, where the page
                  // turns from plans to history. Its own titled section, not
                  // a card in the Upcoming run — an unlabeled map over a
                  // stats panel is the "Up next" hero's silhouette, so at the
                  // 8px card gap it read as another upcoming trip. The header
                  // and the card share one gate: a title with nothing under
                  // it is worse than neither.
                  //
                  // AppSpacing.xl is this page's section seam from here down —
                  // Past trips and Shared with you use the same 24px, so the
                  // three sections below Upcoming read as peers. Dropping any
                  // one of them back to sm re-attaches that section to the one
                  // above it.
                  if (showFootprint) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs, AppSpacing.xl, 0, AppSpacing.sm),
                      child: SectionHeader(
                        title: l10n.tripsListYourTravels,
                        // The band's own gap-filler (specs/log-past-trip): the
                        // section reads as "everywhere you've been" while
                        // knowing only what this app planned, so the way to
                        // correct it belongs in its header. It can't be the
                        // ONLY way in — the header is gated at 2+ owned trips
                        // — hence the app-bar and empty-state twins.
                        action: TextButton.icon(
                          key: kLogTripSectionActionKey,
                          onPressed: () => openLogTripOnTripsTab(ref),
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(l10n.logTripAction),
                        ),
                      ),
                    ),
                    TravelFootprintCard(
                      pins: pins,
                      traveled: stats.traveled,
                      planned: stats.planned,
                    ),
                  ],
                  if (groups.past.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xl),
                      child: CollapsibleSection(
                        title: l10n.tripsListPastTrips,
                        icon: Icons.history,
                        // Teases the latest finished trip rather than
                        // aggregating: the lifetime aggregate now lives one
                        // card up, and "where you just were" is what earns
                        // the expand tap.
                        summary: _pastSummary(groups.past.first, l10n),
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
                              _TripCard(
                                  trip: t, isAdmin: isAdmin, isPast: true),
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
                          AppSpacing.xs, AppSpacing.xl, 0, AppSpacing.sm),
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
          // The entry point that covers the gap the other two leave: an
          // account with exactly one trip sees neither the empty state nor
          // "Your travels" (gated at 2+), and is precisely the account whose
          // history is missing.
          IconButton(
            key: kLogTripAppBarKey,
            tooltip: l10n.logTripAction,
            icon: const Icon(Icons.edit_calendar_outlined),
            onPressed: () => openLogTripOnTripsTab(ref),
          ),
          IconButton(
            tooltip: l10n.importFromAi,
            icon: const Icon(Icons.content_paste_go),
            onPressed: () => openImportOnTripsTab(ref),
          ),
          const AccountMenu(),
        ],
      ),
      body: body,
    );
  }
}

/// One-line tease for the collapsed "Past trips" row: the most recent past
/// trip's destinations and length ("Lisbon & Porto · 12 days"), composed from
/// the same helpers the cards use. Segments drop out individually — a
/// city-less legacy trip falls back to its headline, an undated one to
/// destinations alone.
String _pastSummary(Trip trip, AppLocalizations l10n) {
  final cities = citiesLabel(
    trip.cities,
    two: (a, b) => l10n.citiesTwo(a, b),
    more: (a, b, n) => l10n.citiesMore(a, b, n),
  );
  final days = dayCount(trip.startDate, trip.endDate, const <int?>[]);
  return [
    cities ?? tripHeadline(trip.title, cities),
    if (days > 0) l10n.tripDurationDays(days),
  ].join(' · ');
}

Future<void> _openTrip(
    BuildContext context, WidgetRef ref, String tripId) async {
  // Guarded here rather than with pushOnce so the resync below is skipped
  // too: a second tap that opened nothing must not refetch the list.
  if (!isTopRoute(context)) return;
  await Navigator.of(context).push(
    locatedRoute(TripDetailScreen(tripId: tripId), tripDetailLocation(tripId)),
  );
  // Re-sync on the way back: the detail screen mutates list-visible facts
  // (booked flips, item/todo add/delete feed the booked-progress pill and
  // item count) and this screen never remounts (IndexedStack keeps tabs
  // alive), so the pop is the list's one refresh point — the counterpart of
  // _patch's "keep list in sync" on the detail side. Fire-and-forget, same
  // as pull-to-refresh.
  ref.invalidate(sharedWithMeProvider);
  unawaited(ref.read(tripsProvider.notifier).loadTrips());
}

/// A single trip in the list. Shows the latest version of its chat; for admins,
/// when the chat produced multiple versions it expands to list the older ones.
class _TripCard extends ConsumerWidget {
  final Trip trip;
  final bool isAdmin;

  /// Past rows drop the packing pill: packing is moot once the trip is over,
  /// and the past group is the densest place to economize.
  final bool isPast;

  const _TripCard({
    required this.trip,
    required this.isAdmin,
    this.isPast = false,
  });

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
    // Same rule as the trip-detail header (_displayTitle) and the promoted
    // cards, via the one shared helper. The cities line below is only shown
    // when it isn't already the headline.
    final headline = tripHeadline(trip.title, cities);
    final showCitiesLine = cities != null && headline != cities;
    // Payload-only facts: duration from the date span (0 without both dates,
    // so undated trips naturally skip the chip) and hub-city count (a
    // "1 city" chip is noise when the cities line/headline already names it).
    final days = dayCount(trip.startDate, trip.endDate, const <int?>[]);
    final cityCount = trip.cities?.length ?? 0;
    // The AI's own blurb, suppressed when it IS the title (a long AI title
    // falls back to the cities headline, which would print it twice).
    final summary = (trip.summary ?? '').trim();
    final showSummary = summary.isNotEmpty && summary != trip.title;

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
                MetaChip(label: range)
              else
                Text(l10n.tripsListCreated(shortDate(trip.createdAt))),
              if (days > 0)
                MetaChip(icon: Icons.schedule, label: l10n.tripDurationDays(days)),
              if (cityCount >= 2)
                MetaChip(
                    icon: Icons.location_city_outlined,
                    label: l10n.tripCitiesCount(cityCount)),
              // Stays are CONTEXT (the payload carries confirmed stays, not a
              // booked-progress denominator the booking pill doesn't already
              // own), so a MetaChip — not another pill.
              if ((trip.stayTotal ?? 0) > 0)
                MetaChip(
                    icon: Icons.hotel_outlined,
                    label: l10n.tripsListStaysCount(trip.stayTotal!)),
              // Booking progress: a STATE pill (StatusPill, label-carrying
              // per its colorblind doctrine), tonal-green once everything is
              // booked. Null fields (full views, old servers, stale offline
              // snapshots) hide it — no local derivation.
              if ((trip.bookingTotal ?? 0) > 0)
                StatusPill.custom(
                  label: l10n.tripsListBookedCount(
                      trip.bookingBooked ?? 0, trip.bookingTotal!),
                  background: trip.bookingBooked == trip.bookingTotal
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  foreground: trip.bookingBooked == trip.bookingTotal
                      ? Theme.of(context).colorScheme.onSecondaryContainer
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              // Packing progress, same STATE-pill treatment as booking (tonal
              // green once everything is in the bag).
              if (!isPast && (trip.packingTotal ?? 0) > 0)
                StatusPill.custom(
                  label: l10n.tripsListPackedCount(
                      trip.packingDone ?? 0, trip.packingTotal!),
                  background: trip.packingDone == trip.packingTotal
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  foreground: trip.packingDone == trip.packingTotal
                      ? Theme.of(context).colorScheme.onSecondaryContainer
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              // Shared OUT (owner has co-planners) — a labeled pill, not a
              // bare icon: the group leading icon already means "shared
              // WITH me" on received trips.
              if (trip.isOwner && trip.shared == true)
                StatusPill.custom(
                  label: l10n.tripsListShared,
                  background:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  foreground: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              // Item count is context, not state: plain text like the
              // planned-with/shared-by attributions, so the row isn't pill
              // soup.
              if ((trip.itemCount ?? 0) > 0)
                Text(
                  l10n.tripsListPlaces(trip.itemCount!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
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
          if (showSummary)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                summary,
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
          onTap: () => _openTrip(context, ref, trip.id),
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
                onTap: () => _openTrip(context, ref, versions[i].id),
              ),
          ],
        );
      },
    );
  }
}
