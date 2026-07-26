import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../models/shared_trip.dart';
import '../models/trip.dart';
import '../navigation/app_nav.dart';
import '../providers/auth_provider.dart';
import '../providers/shared_trip_provider.dart';
import '../providers/shared_with_me_provider.dart';
import '../providers/trips_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/map_day_chips.dart';
import '../widgets/trip_map.dart';
import 'auth_screen.dart';
import 'trip_detail_screen.dart';
import '../utils/snack.dart';

/// Which kind of link opened this screen: a share link (multi-use, viewer or
/// editor) or an emailed invite (single-use, editor). The two return the
/// same payload from different endpoints and redeem differently.
enum SharedLinkKind { share, invite }

/// Public read-only view of a shared trip, reachable at /#/share/<token>
/// without an account. Signed-in viewers can save a copy to their own trips.
class SharedTripScreen extends ConsumerWidget {
  final String token;
  final SharedLinkKind linkKind;
  const SharedTripScreen(
      {super.key, required this.token, this.linkKind = SharedLinkKind.share});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shared = ref.watch(linkKind == SharedLinkKind.invite
        ? invitedTripProvider(token)
        : sharedTripProvider(token));
    final l10n = context.l10n;
    return Scaffold(
      appBar: GradientAppBar(
        title: shared.maybeWhen(
          data: (s) => Text(s.trip.title),
          orElse: () => Text(l10n.sharedTitle),
        ),
      ),
      body: shared.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.link_off,
          title: l10n.sharedUnavailableTitle,
          message: linkKind == SharedLinkKind.invite
              ? l10n.sharedInviteUnavailableMessage
              : l10n.sharedLinkUnavailableMessage,
          actions: [
            // A transient network blip shouldn't read as a dead link — let
            // the viewer refetch before giving up.
            FilledButton(
              onPressed: () => ref.invalidate(linkKind == SharedLinkKind.invite
                  ? invitedTripProvider(token)
                  : sharedTripProvider(token)),
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
        data: (s) =>
            _SharedTripBody(shared: s, token: token, linkKind: linkKind),
      ),
    );
  }
}

/// Scroll clearance for the pinned bottom action bar (excluding the SafeArea
/// inset, added at the call site): the bar measures ~104px at its tallest —
/// 2 x AppSpacing.md container padding + two stacked ~40px buttons — so this
/// keeps the last row fully revealable with breathing room to spare.
const double _actionBarClearance = 128;

class _SharedTripBody extends ConsumerStatefulWidget {
  final SharedTrip shared;
  final String token;
  final SharedLinkKind linkKind;
  const _SharedTripBody(
      {required this.shared, required this.token, required this.linkKind});

  @override
  ConsumerState<_SharedTripBody> createState() => _SharedTripBodyState();
}

class _SharedTripBodyState extends ConsumerState<_SharedTripBody> {
  bool _saving = false;
  int? _selectedPosition;
  // Map day-chip selection; null = All. Shared views always default to All
  // and get none of the Today behaviors (specs/today-mode).
  int? _selectedDay;

  Trip get _trip => widget.shared.trip;

  /// Groups items by hub city (day_trip_from ?? city) in itinerary order —
  /// the same locality rule the owner's trip detail uses.
  List<({String label, List<ItineraryItem> items})> _groups(
      AppLocalizations l10n) {
    final items = _trip.items ?? const <ItineraryItem>[];
    final groups = <({String label, List<ItineraryItem> items})>[];
    for (final it in items) {
      final hub = (it.dayTripFrom?.trim().isNotEmpty ?? false)
          ? it.dayTripFrom!.trim()
          : (it.city?.trim().isNotEmpty ?? false)
              ? it.city!.trim()
              : l10n.sharedPlacesGroup;
      if (groups.isEmpty || groups.last.label != hub) {
        groups.add((label: hub, items: <ItineraryItem>[]));
      }
      groups.last.items.add(it);
    }
    return groups;
  }

  /// Routes through sign-in if needed; true when a session exists after.
  Future<bool> _ensureSignedIn() async {
    if (ref.read(authProvider).isSignedIn) return true;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
    return ref.read(authProvider).isSignedIn;
  }

  Future<void> _saveCopy() async {
    final l10n = context.l10n;
    if (!await _ensureSignedIn()) return;
    setState(() => _saving = true);
    try {
      await ref.read(tripsApiServiceProvider).duplicateSharedTrip(widget.token);
      if (!mounted) return;
      // Land the viewer on their Trips tab, where the copy now lives.
      ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    } catch (e) {
      if (mounted) {
        showSnack(context, l10n.sharedSaveCopyError(friendlyError(l10n, e)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Redeems membership — editor links join as co-planner, viewer links as a
  /// read-only follow — then lands in the shared trip itself (Trips tab
  /// underneath so back lands somewhere sensible).
  Future<void> _joinAsCoPlanner() async {
    final l10n = context.l10n;
    if (!await _ensureSignedIn()) return;
    setState(() => _saving = true);
    try {
      final service = ref.read(tripsApiServiceProvider);
      final tripId = widget.linkKind == SharedLinkKind.invite
          ? await service.acceptInvite(widget.token)
          : await service.joinSharedTrip(widget.token);
      if (!mounted) return;
      ref.invalidate(sharedWithMeProvider);
      ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
      // Read before navigating: pushNamedAndRemoveUntil disposes this state,
      // so the callbacks below must not touch ref.
      final navKeys = ref.read(tabNavKeysProvider);
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
      // The shell (and the Trips tab's nested navigator) remounts over the
      // next frames; retry until it's attached rather than betting on one
      // frame and silently dropping the push. If every attempt misses, the
      // user still lands on the Trips tab where the joined trip now shows.
      void openOnTripsTab([int attempts = 10]) {
        final nav = navKeys[AppTab.trips.index].currentState;
        if (nav != null) {
          nav.push(MaterialPageRoute(
              builder: (_) => TripDetailScreen(tripId: tripId)));
        } else if (attempts > 0) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => openOnTripsTab(attempts - 1));
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) => openOnTripsTab());
    } catch (e) {
      if (mounted) {
        showSnack(context, l10n.sharedJoinError(friendlyError(l10n, e)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final trip = _trip;
    final items = trip.items ?? const <ItineraryItem>[];
    final dates = tripDateRange(trip.startDate, trip.endDate);
    final stays = trip.accommodations ?? const <Accommodation>[];
    // The map-visibility gate stays keyed to the unfiltered items/stays so the
    // chip row never disappears when the selected day has nothing mappable. A
    // geocoded stay counts on its own: TripMap renders stay pins, so a
    // stays-only trip still has a map worth showing.
    final hasCoords = items.any((i) => i.latitude != 0 || i.longitude != 0) ||
        stays.any(TripMap.stayHasCoords);
    final mapDayCount =
        dayCount(trip.startDate, trip.endDate, items.map((i) => i.day));
    if (_selectedDay != null && _selectedDay! > mapDayCount) {
      _selectedDay = null; // trip shrank under a stale selection
    }
    // Days that would plot something, so empty days get muted chips.
    final mappedDays = daysWithMappedContent(
      trip.startDate,
      mapDayCount,
      [
        for (final i in items)
          if (i.latitude != 0 || i.longitude != 0) i.day,
      ],
      [
        for (final a in stays)
          if (TripMap.stayHasCoords(a))
            (checkIn: a.checkIn, checkOut: a.checkOut),
      ],
    );
    final dayItems = _selectedDay == null
        ? items
        : items.where((i) => i.day == _selectedDay).toList();
    // Under Day N, only the stay(s) covering that night (checkout-exclusive);
    // without a parseable start date no stay can match a day.
    final tripStart = DateTime.tryParse(trip.startDate ?? '');
    final dayStays = _selectedDay == null
        ? stays
        : tripStart == null
            ? const <Accommodation>[]
            : stays
                .where((a) => stayCoversDate(
                    a.checkIn,
                    a.checkOut,
                    // Calendar-day arithmetic (constructor normalizes
                    // overflow) so a DST transition can't drift the date.
                    DateTime(tripStart.year, tripStart.month,
                        tripStart.day + _selectedDay! - 1)))
                .toList();

    return Stack(
      children: [
        ListView(
          // Bottom pad must clear the pinned action bar: 12+12 container
          // padding + two stacked ~40px buttons ≈ 104px, plus the SafeArea
          // bottom inset the bar consumes on gesture-bar phones — otherwise
          // the last row hides behind the opaque bar even fully scrolled.
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              _actionBarClearance + MediaQuery.paddingOf(context).bottom),
          children: [
            // Centered 700px column on wide layouts (declutter series):
            // the ListView stays full-width (wheel/scrollbar work in the
            // gutters) while the content is capped, same as the trips list.
            PageContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(trip.title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${l10n.sharedBy(widget.shared.ownerName)}'
                    '${dates != null ? ' · $dates' : ''}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (trip.summary != null &&
                      trip.summary!.trim().isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text(trip.summary!, style: theme.textTheme.bodyMedium),
                  ],
                  if (hasCoords) ...[
                    const SizedBox(height: AppSpacing.lg),
                    ClipRRect(
                      borderRadius: AppRadius.lgAll,
                      child: SizedBox(
                        height: 240,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: TripMap(
                                items: dayItems,
                                accommodations: dayStays,
                                selectedPosition: _selectedPosition,
                                fitSignature: _selectedDay,
                                // Keep fitted markers clear of the chip row
                                // overlaid below.
                                topOverlayInset: mapDayCount > 0
                                    ? MapDayChips.mapTopInset
                                    : 0,
                                emptyLabel: _selectedDay == null
                                    ? l10n.sharedNoMappedPlaces
                                    : l10n.sharedNoPlacesOnDay(_selectedDay!),
                                onPinTap: (pos) =>
                                    setState(() => _selectedPosition = pos),
                              ),
                            ),
                            // Above the map's gesture layer, so chip taps and row
                            // scrolls never pan the map.
                            Positioned(
                              top: 8,
                              left: 8,
                              right: 8,
                              child: MapDayChips(
                                dayCount: mapDayCount,
                                selected: _selectedDay,
                                mappedDays: mappedDays,
                                onSelected: (d) =>
                                    setState(() => _selectedDay = d),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  if (items.isEmpty)
                    EmptyState(
                      icon: Icons.place_outlined,
                      title: l10n.sharedEmptyTitle,
                      message: l10n.sharedEmptyMessage,
                    )
                  else
                    for (final group in _groups(l10n)) ...[
                      Padding(
                        padding: const EdgeInsets.only(
                            top: AppSpacing.md, bottom: AppSpacing.xs),
                        // Same header treatment as the Stays section below — one
                        // type system per screen.
                        child: SectionHeader(title: group.label),
                      ),
                      for (final it in group.items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: theme.colorScheme.primary
                                .withValues(alpha: 0.12),
                            child: Text(
                              '${it.position + 1}',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.primary),
                            ),
                          ),
                          title: Text(it.name),
                          subtitle:
                              it.address != null ? Text(it.address!) : null,
                          trailing: it.day != null
                              ? Chip(
                                  label: Text(l10n.sharedDayN(it.day!)),
                                  visualDensity: VisualDensity.compact,
                                )
                              : null,
                          selected: _selectedPosition == it.position,
                          onTap: () =>
                              setState(() => _selectedPosition = it.position),
                        ),
                    ],
                  if ((trip.accommodations ?? const []).isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    SectionHeader(title: l10n.sharedStays),
                    for (final a in trip.accommodations!)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.hotel_outlined),
                        title: Text(a.name),
                        subtitle: a.address != null ? Text(a.address!) : null,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            color: theme.scaffoldBackgroundColor,
            // Background stays full-bleed over the scroll edge; the buttons
            // cap to the same 700px column as the content above.
            child: SafeArea(
              child: PageContainer(
                child: widget.shared.isEditorLink
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton.icon(
                            onPressed: _saving ? null : _joinAsCoPlanner,
                            icon: _saving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.group_add_outlined),
                            label: Text(l10n.sharedJoinCoPlanner),
                          ),
                          // Invite tokens have no duplicate endpoint — they're
                          // single-use join capabilities, not browse links.
                          if (widget.linkKind == SharedLinkKind.share)
                            TextButton(
                              onPressed: _saving ? null : _saveCopy,
                              child: Text(l10n.sharedSaveSeparateCopy),
                            ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Viewer follow (specs/share-ux-viewer-follow): the
                          // trip appears read-only in "Shared with you" and
                          // stays current as the owner plans.
                          FilledButton.icon(
                            onPressed: _saving ? null : _joinAsCoPlanner,
                            icon: _saving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.bookmark_add_outlined),
                            label: Text(l10n.sharedKeepInTrips),
                          ),
                          TextButton(
                            onPressed: _saving ? null : _saveCopy,
                            child: Text(l10n.sharedSaveSeparateCopy),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
