import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../models/shared_trip.dart';
import '../models/trip.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/auth_provider.dart';
import '../providers/shared_trip_provider.dart';
import '../providers/shared_with_me_provider.dart';
import '../providers/trips_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/leg_ranges.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import '../utils/trip_legs.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/map_leg_chips.dart';
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
  // Focused leg on the map (specs/map-city-focus); null = All, keyed by the
  // tripLegs run key. Shared views always default to All and get none of the
  // Today behaviors (specs/today-mode). Chips drive the MAP only — the
  // read-only list below has plain section headers, no expansion to sync.
  String? _focusedLegKey;

  Trip get _trip => widget.shared.trip;

  /// Groups items by hub city in itinerary order — the same shared [tripLegs]
  /// rule the owner's trip detail uses (day_trip_from ?? city ?? a city
  /// parsed from the address).
  List<({String label, List<ItineraryItem> items})> _groups(
      AppLocalizations l10n) {
    return [
      for (final leg in tripLegs(_trip.items ?? const <ItineraryItem>[]))
        (
          label: leg.label == kOtherPlacesLabel
              ? l10n.sharedPlacesGroup
              : leg.label,
          items: leg.items,
        ),
    ];
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
      // so the callback below must not touch ref.
      final navKeys = ref.read(tabNavKeysProvider);
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
      // The shell (and the Trips tab's nested navigator) remounts over the
      // next frames; pushOnTabWhenReady retries until it's attached rather
      // than betting on one frame and silently dropping the push. Deferred a
      // frame so the push can't land on a navigator the reset just discarded.
      // If every attempt misses, the user still lands on the Trips tab where
      // the joined trip now shows.
      WidgetsBinding.instance.addPostFrameCallback((_) => pushOnTabWhenReady(
          navKeys,
          AppTab.trips,
          () => locatedRoute(
              TripDetailScreen(tripId: tripId), tripDetailLocation(tripId))));
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
    // chip row never disappears when the focused leg has nothing mappable. A
    // geocoded stay counts on its own: TripMap renders stay pins, so a
    // stays-only trip still has a map worth showing.
    final hasCoords = items.any((i) => i.latitude != 0 || i.longitude != 0) ||
        stays.any(TripMap.stayHasCoords);
    // The canonical locality runs (shared tripLegs split) drive the chips,
    // the per-leg map filter, and — index-aligned by construction — the
    // rawLegRanges the stay filter reads.
    final legs = tripLegs(items);
    final rawRanges = rawLegRanges(trip);
    if (_focusedLegKey != null &&
        (legs.length < 2 || !legs.any((l) => l.key == _focusedLegKey))) {
      _focusedLegKey = null; // trip changed under a stale focus
    }
    final legChips = <({String key, String label})>[
      for (final leg in legs)
        (
          key: leg.key,
          label: leg.label == kOtherPlacesLabel
              ? l10n.sharedPlacesGroup
              : leg.label,
        ),
    ];
    // Legs that would plot something, so unmappable legs get muted chips: a
    // geocoded item in the run, or a geocoded stay on one of its nights —
    // the same rule as the owner's mappedLegKeys.
    final mappedLegKeys = <String>{
      for (var i = 0; i < legs.length; i++)
        if (legs[i].coord != null ||
            (rawRanges[i].start != null &&
                rawRanges[i].end != null &&
                stays.any((a) =>
                    TripMap.stayHasCoords(a) &&
                    stayCoversAnyNight(a.checkIn, a.checkOut,
                        rawRanges[i].start!, rawRanges[i].end!))))
          legs[i].key,
    };
    final focusIndex = _focusedLegKey == null
        ? -1
        : legs.indexWhere((l) => l.key == _focusedLegKey);
    final legItems = focusIndex < 0 ? items : legs[focusIndex].items;
    // Under a focused leg, only the stay(s) covering one of its raw-range
    // nights (checkout-exclusive both sides); an undated leg plots none.
    final legStays = focusIndex < 0
        ? stays
        : (rawRanges[focusIndex].start == null ||
                rawRanges[focusIndex].end == null)
            ? const <Accommodation>[]
            : stays
                .where((a) => stayCoversAnyNight(
                    a.checkIn,
                    a.checkOut,
                    rawRanges[focusIndex].start!,
                    rawRanges[focusIndex].end!))
                .toList();
    // Trip-overview destination pins (All chip only): one numbered pin per
    // city leg, from the unfiltered itinerary. Label-only tooltips — the
    // owner-side date allocation doesn't exist on this read-only view.
    final destinations = _focusedLegKey != null
        ? null
        : <TripMapDestination>[
            for (final leg in legs)
              if (leg.coord != null)
                TripMapDestination(
                  label: leg.label == kOtherPlacesLabel
                      ? l10n.sharedPlacesGroup
                      : leg.label,
                  point: LatLng(leg.coord!.lat, leg.coord!.lng),
                ),
          ];

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
                        // Match the trip-detail map band: taller on wide
                        // layouts so the auto-fit can show every pin.
                        height:
                            MediaQuery.sizeOf(context).width >= kRailBreakpoint
                            ? 340
                            : 240,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: TripMap(
                                items: legItems,
                                accommodations: legStays,
                                destinations: destinations,
                                selectedPosition: _selectedPosition,
                                fitSignature: _focusedLegKey,
                                // Keep fitted markers clear of the chip row
                                // overlaid below.
                                topOverlayInset: legChips.length >= 2
                                    ? MapLegChips.mapTopInset
                                    : 0,
                                emptyLabel: focusIndex < 0
                                    ? l10n.sharedNoMappedPlaces
                                    : l10n.sharedNoPlacesIn(
                                        legChips[focusIndex].label),
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
                              child: MapLegChips(
                                legs: legChips,
                                selected: _focusedLegKey,
                                mappedLegKeys: mappedLegKeys,
                                // Clear the pin selection with the focus
                                // change, same rule as the owner surfaces.
                                onSelected: (k) => setState(() {
                                  _focusedLegKey = k;
                                  _selectedPosition = null;
                                }),
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
