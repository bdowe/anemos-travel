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

/// Handle for the "Your travels" section's atlas door. Locale-free, the same
/// convention: the invariant is whether the door EXISTS for this account, and
/// a text finder would answer it differently in Spanish.
const kTravelAtlasSeeAllKey = ValueKey('travelAtlas.entry.section');

/// The trips list, read as a journal index rather than a dashboard.
///
/// The page runs in narrative order — **what's next, what you're co-planning,
/// where you've been, everywhere you've been** — so each section answers a
/// question the one above it raises, and the retrospective closes the page
/// instead of interrupting the run of plans. "Your travels" sat mid-page until
/// the editorial pass, which put a second map (and a panel of lifetime totals)
/// between a traveler and their own past trips.
///
/// Two treatments carry the whole page: the promoted hero — the one saturated
/// object here — and a plain row whose hierarchy is typographic. Rows print
/// their facts in three registers: the title, then the trip's dates in the
/// row's second weight, then everything else quiet. A fact is a filled chip
/// ONLY when it is state someone can act on (booked, packed, shared); context
/// (stays, places) is muted text, which is the same rule [TripHeroCard]
/// already followed. Before that split the rows carried up to seven filled
/// chips of equal weight, and the ones that mattered were indistinguishable
/// from the ones that didn't.
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
      // been travelled and what's still planned. Gated at 2+: an aggregate of
      // one trip only restates the hero.
      final stats = travelStats(state.trips, now);
      final pins = footprintPins(state.trips, now);
      final showFootprint = state.trips.length >= 2;
      // The atlas door opens on FINISHED trips (tripIsPast), not on the card's
      // own owned-trip count and not on travelStats' traveled count — that one
      // partitions on tripHasStarted, so it would open for someone on their
      // second-ever trip, mid-flight. Below two there is nothing behind the
      // door: no traveled pins, no Traveled colophon group (it doesn't render
      // at zero) and an index with no rows at all. So the door doesn't exist,
      // and the header keeps "+ Add past trip", which is how the history that
      // unlocks the atlas gets here in the first place.
      final showAtlas = pastTrips(state.trips, now).length >= 2;
      body = RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(sharedWithMeProvider);
          ref.invalidate(resumableChatsProvider);
          await ref.read(tripsProvider.notifier).loadTrips();
        },
        child: ListView(
          // Bottom air on the ladder (xxl): the page now ENDS on the
          // retrospective card, and a card that stops flush against the
          // viewport floor reads as a page that got cut off.
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
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
                  // bar's "My trips" again) mirrors "Past trips" below, and
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
                  // Trips others invited this user to co-plan, directly under
                  // the traveler's own plans: "mine" then "ours" then "was",
                  // which is the order someone actually asks these questions
                  // in. Kept a separate section — "mine" vs "shared with me"
                  // is the mental model, and the row shows the owner instead
                  // of admin version chrome.
                  //
                  // AppSpacing.xl is this page's section seam from here down.
                  // Dropping any one of them back to sm re-attaches that
                  // section to the one above it.
                  if (sharedOrdered.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs, AppSpacing.xl, 0, AppSpacing.sm),
                      child: SectionHeader(title: l10n.tripsListSharedWithYou),
                    ),
                    for (final t in sharedOrdered)
                      _TripCard(trip: t, isAdmin: false),
                  ],
                  // Finished trips. The group is still collapsed by default —
                  // a trips page is about what's ahead — but it is no longer a
                  // bare row floating between two card runs, which is how a
                  // whole travel history came to be the easiest thing on the
                  // page to miss. It now sits in a section card of its own
                  // weight, and opens into a quiet index INSIDE that card:
                  // one bounded object, not six more cards.
                  if (groups.past.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xl),
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                              vertical: AppSpacing.xs),
                          child: CollapsibleSection(
                            title: l10n.tripsListPastTrips,
                            icon: Icons.history,
                            // Teases the latest finished trip rather than
                            // aggregating: the lifetime aggregate lives in
                            // "Your travels" below, and "where you just were"
                            // is what earns the expand tap.
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
                                for (var i = 0; i < groups.past.length; i++) ...[
                                  // Hairlines between rows, never around them:
                                  // the section card already draws the box, so
                                  // a divider only has to separate siblings —
                                  // and the first row needs none, its header
                                  // is directly above it.
                                  if (i > 0) const Divider(height: 1),
                                  _TripCard(
                                    trip: groups.past[i],
                                    isAdmin: isAdmin,
                                    isPast: true,
                                    flat: true,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // The retrospective closes the page: everywhere this
                  // traveler has been, on one map, captioned by the numbers.
                  // It used to sit between the upcoming run and the past
                  // trips, where an unlabeled map over a stats panel was the
                  // "Up next" hero's silhouette — and where it put a second
                  // map in the middle of a scroll about plans. The header and
                  // the card share one gate: a title with nothing under it is
                  // worse than neither.
                  if (showFootprint) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs, AppSpacing.xl, 0, AppSpacing.sm),
                      child: SectionHeader(
                        title: l10n.tripsListYourTravels,
                        // Two actions, passed as one WRAP — not a Row.
                        // SectionHeader's own Wrap already drops this whole
                        // group onto its own line, which is what its dartdoc
                        // promises and what a phone gets: verified in the
                        // browser, 360dp English keeps the title and both
                        // actions on ONE line, and Spanish drops the pair
                        // together onto a second. A Row would render
                        // identically at every shipped width — the Wrap is
                        // here so the pair CAN break inside itself if it ever
                        // has to (a large accessibility text scale, a longer
                        // translation) instead of overflowing.
                        //
                        // Both actions stay here. "+ Add past trip" does not
                        // move: specs/log-past-trip placed it in this header
                        // deliberately, and relocating it re-opens that
                        // decision.
                        // Runs stack flush-LEFT in the rare case the pair
                        // does break, so the buttons land on the title's own
                        // edge rather than lining up on the wider button's
                        // right edge, which is neither margin.
                        action: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            // The way into the atlas. A marked action rather
                            // than a tappable card: the card carries no
                            // affordance, and every pin on it is a 44px hit
                            // box already spending taps on a tooltip — the
                            // most inviting targets would be the ones that
                            // didn't open it.
                            if (showAtlas)
                              TextButton(
                                key: kTravelAtlasSeeAllKey,
                                onPressed: () => openAtlasOnTripsTab(ref),
                                child: Text(l10n.travelAtlasSeeAll),
                              ),
                            // The band's own gap-filler
                            // (specs/log-past-trip): the section reads as
                            // "everywhere you've been" while knowing only what
                            // this app planned, so the way to correct it
                            // belongs in its header. It can't be the ONLY way
                            // in — the header is gated at 2+ owned trips —
                            // hence the app-bar and empty-state twins.
                            TextButton.icon(
                              key: kLogTripSectionActionKey,
                              onPressed: () => openLogTripOnTripsTab(ref),
                              icon: const Icon(Icons.add, size: 18),
                              label: Text(l10n.logTripAction),
                            ),
                          ],
                        ),
                      ),
                    ),
                    TravelFootprintCard(
                      pins: pins,
                      traveled: stats.traveled,
                      planned: stats.planned,
                    ),
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
        title: l10n.tripsListTitle,
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

/// A single trip in the list, as an editorial row: title, then the trip's
/// dates in the row's second weight, then everything else quiet.
///
/// The dates earned their own line by being the fact a list of trips is
/// actually scanned for; they used to be the first of up to seven equal-weight
/// filled chips. Duration joins them there rather than taking a chip of its
/// own — "Aug 2 – Aug 20 · 19 days" is one thought — and the city COUNT is
/// gone entirely, because the cities line below (or the headline itself) names
/// them, and a card that says "3 cities" directly above "Lisbon, Porto &
/// Madrid" is counting out loud for no one.
///
/// No leading glyph: every row in a list of trips is a trip, so the icon said
/// nothing and cost the titles their shared left edge. The one thing it did
/// carry — whose trip this is — is carried by words instead ("Planned with
/// Ana" / "Shared by Ana"), under a section header that already said it.
///
/// For admins, when the chat produced multiple versions the row expands to
/// list the older ones.
class _TripCard extends ConsumerWidget {
  final Trip trip;
  final bool isAdmin;

  /// Past rows drop the packing pill: packing is moot once the trip is over,
  /// and the past group is the densest place to economize.
  final bool isPast;

  /// Renders without its own [Card] — for the "Past trips" section, which is
  /// one bounded card holding a quiet index. A card inside a card reads as a
  /// mistake, and six of them read as the run of upcoming trips again.
  final bool flat;

  const _TripCard({
    required this.trip,
    required this.isAdmin,
    this.isPast = false,
    this.flat = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final versions = trip.versionCount ?? 1;
    final hasHistory = isAdmin && versions > 1 && trip.chatId != null;

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
    // Payload-only facts: the date span (0 without both dates, so an undated
    // trip naturally skips the duration) and, failing that, when the trip was
    // created — a row always says WHEN something, or it is just a name.
    final range = tripDateRange(trip.startDate, trip.endDate);
    final days = dayCount(trip.startDate, trip.endDate, const <int?>[]);
    final whenLine = range == null
        ? l10n.tripsListCreated(shortDate(trip.createdAt))
        : [range, if (days > 0) l10n.tripDurationDays(days)].join(' · ');
    // The AI's own blurb, suppressed when it IS the title (a long AI title
    // falls back to the cities headline, which would print it twice).
    final summary = (trip.summary ?? '').trim();
    final showSummary = summary.isNotEmpty && summary != trip.title;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    // State first, context after — the same order the hero uses, so a trip
    // reads the same whether it is promoted or listed. Everything here is
    // null/zero-hiding: the server row is the one derivation for list display
    // (old servers and stale offline snapshots simply say less).
    final meta = <Widget>[
      // Booking progress: a STATE pill (StatusPill, label-carrying per its
      // colorblind doctrine), tonal-green once everything is booked.
      if ((trip.bookingTotal ?? 0) > 0)
        StatusPill.custom(
          label: l10n.tripsListBookedCount(
              trip.bookingBooked ?? 0, trip.bookingTotal!),
          background: trip.bookingBooked == trip.bookingTotal
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          foreground: trip.bookingBooked == trip.bookingTotal
              ? theme.colorScheme.onSecondaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      // Packing progress, same STATE-pill treatment as booking.
      if (!isPast && (trip.packingTotal ?? 0) > 0)
        StatusPill.custom(
          label: l10n.tripsListPackedCount(
              trip.packingDone ?? 0, trip.packingTotal!),
          background: trip.packingDone == trip.packingTotal
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          foreground: trip.packingDone == trip.packingTotal
              ? theme.colorScheme.onSecondaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      // Shared OUT (owner has co-planners): state, and the only pill a row
      // carries that isn't progress.
      if (trip.isOwner && trip.shared == true)
        StatusPill.custom(
          label: l10n.tripsListShared,
          background: theme.colorScheme.surfaceContainerHighest,
          foreground: theme.colorScheme.onSurfaceVariant,
        ),
      // Context: what the trip HAS, which nobody acts on from this page.
      if ((trip.stayTotal ?? 0) > 0)
        _Fact(
            icon: Icons.hotel_outlined,
            label: l10n.tripsListStaysCount(trip.stayTotal!)),
      if ((trip.itemCount ?? 0) > 0)
        _Fact(
            icon: Icons.place_outlined,
            label: l10n.tripsListPlaces(trip.itemCount!)),
      if (!trip.isOwner && (trip.ownerName ?? '').isNotEmpty)
        Text(
          trip.canEdit
              ? l10n.tripsListPlannedWith(trip.ownerName!)
              : l10n.tripsListSharedBy(trip.ownerName!),
          style: muted,
        ),
    ];

    Widget content({required bool chevron}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    headline,
                    // Two lines before it gives: a trip's name is the one
                    // thing on the row that can't be re-derived from the rest
                    // of it, and phone widths ellipsize a real title at one.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (hasHistory) ...[
                  const SizedBox(width: AppSpacing.sm),
                  _VersionBadge(count: versions),
                ],
                if (chevron) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Icon(Icons.chevron_right,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              whenLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
            if (showCitiesLine)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(cities,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
              ),
            if (meta.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: meta,
                ),
              ),
            // Prose last, after the factual lines have clustered.
            if (showSummary)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(summary,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
              ),
          ],
        );

    if (hasHistory) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          // The expander's own chevron replaces the row's: two on one row
          // would promise two different things.
          title: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: content(chevron: false),
          ),
          childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
          children: [
            _VersionList(chatId: trip.chatId!, latestId: trip.id),
          ],
        ),
      );
    }

    final row = InkWell(
      onTap: () => _openTrip(context, ref, trip.id),
      child: Padding(
        // Flat rows take their horizontal padding from the section card that
        // holds them, so the hairlines between them run the card's width.
        padding: flat
            ? const EdgeInsets.symmetric(vertical: AppSpacing.md)
            : const EdgeInsets.all(AppSpacing.lg),
        child: content(chevron: true),
      ),
    );
    return flat ? row : Card(clipBehavior: Clip.antiAlias, child: row);
  }
}

/// A context fact on a row: a muted glyph and a muted label, no fill. The
/// glyph is what separates one fact from the next, which is why these need no
/// dots and no chip — a filled chip on this page means "state", and stays
/// [StatusPill]'s alone.
class _Fact extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Fact({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.xs),
        // Flexible + ellipsis: a fact wider than the Wrap run it landed in
        // has nowhere to wrap to, so it truncates rather than striping the
        // card with a RenderFlex overflow.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
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
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
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
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
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
