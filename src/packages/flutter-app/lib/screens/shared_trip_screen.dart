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
import '../theme/app_typography.dart';
import '../theme/spacing.dart';
import '../utils/date_formats.dart';
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
import '../widgets/trip_map_destinations.dart' show mapLegChipEntries;
import 'auth_screen.dart';
import 'trip_detail_screen.dart';
import '../utils/snack.dart';

/// Which kind of link opened this screen: a share link (multi-use, viewer or
/// editor) or an emailed invite (single-use, editor). The two return the
/// same payload from different endpoints and redeem differently.
enum SharedLinkKind { share, invite }

/// This view names the unresolved-locality run **"Places"**, not trip detail's
/// "Other places" ([groupLabelText]) — three surfaces here speak it: the
/// section headers, the map's destination pins, and the map chip strip. One
/// definition so a chip can never disagree with the header beneath it.
String _sharedLegLabel(AppLocalizations l10n, String label) =>
    label == kOtherPlacesLabel ? l10n.sharedPlacesGroup : label;

/// One leg's rendered dates: the formatted range, and a nights label that
/// carries its OWN leading "· " (see [_legDates]).
typedef _LegDates = ({String range, String? nights});

/// A leg's date range as this view renders it — the twin of trip detail's
/// per-leg date chip (`TripDerivation.compute`, trip_detail_derivation.dart).
/// Both read [visibleLegRanges] and format it identically, so the two surfaces
/// cannot name the same leg different dates.
///
/// Null when the leg has no rendered dates, which is how a **dateless trip**
/// renders its city names with no range at all: the absence is carried, never
/// substituted for. There is deliberately no fallback here — a day number or a
/// guessed date would be this view inventing a fact the trip does not hold.
_LegDates? _legDates(AppLocalizations l10n, LegRange range) {
  final start = range.start;
  final end = range.end;
  if (start == null || end == null) return null;
  final nights = nightsBetween(start, end);
  return (
    range: formatShortRange(start, end),
    // `tripLegNights` owns the leading "· ", so a **zero-night** leg drops the
    // middot structurally rather than through a conditional in a format
    // string — which is also why the range and the nights stay two Texts at
    // every render site below, never one interpolated string.
    nights: nights > 0 ? l10n.tripLegNights(nights) : null,
  );
}

/// The date chip's metrics, adopted from trip detail's city header
/// (`itinerary_tab.dart`) so the two headers measure the same.
const double _chipIconSize = 14;
const double _chipIconGap = 4;
const double _chipInnerGap = 8;

/// Bound for the wide header's date chip. Trip detail sizes its chip to a
/// per-build width measured across every group so the chips align as columns;
/// this view has no such column to join — one header, one chip, sized to its
/// own text — so the shared width buys nothing here and only the pathological
/// cap carries over: at an extreme text scale the chip stops growing and
/// ellipsizes instead of pushing the city name off its own row.
const double _chipMaxWidth = 200;

/// How many place names a city line shows before it caps with "+N more".
///
/// A count, not a measured line budget: the number of lines a run of names
/// occupies depends on the font, and this repo does not let layout be claimed
/// from anywhere but the running app. Narrow takes the tighter cap for the
/// reason the design artifact gives — on a phone a dozen names on "one line"
/// wraps into a paragraph that scans worse than the list it replaced.
const int _placesCapWide = 6;
const int _placesCapNarrow = 4;

/// The header's leading pin and the gap after it, adopted from trip detail's
/// city header. [_pinColumnWidth] is what the places line indents by, so a
/// city's places hang under its NAME rather than under its pin — an alignment
/// derived from the two values above it, not a number picked off the spacing
/// ladder, so it has to move if either of them does.
const double _pinSize = 18;
const double _pinGap = 6;
const double _pinColumnWidth = _pinSize + _pinGap;

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
          data: (s) => s.trip.title,
          orElse: () => l10n.sharedTitle,
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
  /// parsed from the address) — each carrying the dates its header renders.
  ///
  /// [ranges] is [visibleLegRanges] for this trip, index-aligned with the
  /// [tripLegs] split by construction: both run that one split over the same
  /// items, which is the alignment the map chip strip above already rides on.
  /// The bounds check is belt-and-braces for a caller that ever passes the
  /// empty list, not a suspicion about the alignment.
  ///
  /// Still the only place a group's label is decided, so [kOtherPlacesLabel]
  /// keeps reaching [_sharedLegLabel] — the section header, the map's
  /// destination pins and the chip strip all speak that one name, and a header
  /// that resolved its own label would be the fourth voice.
  List<({String label, List<ItineraryItem> items, _LegDates? dates})> _groups(
      AppLocalizations l10n, List<LegRange> ranges) {
    final legs = tripLegs(_trip.items ?? const <ItineraryItem>[]);
    return [
      for (var i = 0; i < legs.length; i++)
        (
          label: _sharedLegLabel(l10n, legs[i].label),
          items: legs[i].items,
          dates: i < ranges.length ? _legDates(l10n, ranges[i]) : null,
        ),
    ];
  }

  /// Routes through sign-in if needed; true when a session exists after.
  Future<bool> _ensureSignedIn() async {
    if (ref.read(authProvider).isSignedIn) return true;
    warmSsoAvailability(context);
    // pushOnce: Join and Save-a-copy both route through here and neither sets
    // its _saving flag until this returns, so a double tap would otherwise
    // stack two auth screens. A blocked call returns not-signed-in, which
    // makes the caller bail — correct, since the first tap owns the flow.
    await pushOnce(
      context,
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
      // the joined trip now shows. instantRoute because this is a deep link
      // landing, not a gesture: after the whole-app reset the trip should be
      // on screen, not slide in over a freshly-remounted trips list.
      WidgetsBinding.instance.addPostFrameCallback((_) => pushOnTabWhenReady(
          navKeys,
          AppTab.trips,
          () => instantRoute(
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
    // The same width question the map band below already asks, asked once:
    // narrow is where a city header stacks its dates under the name instead of
    // carrying them as a chip on the right, which is trip detail's own switch
    // at this same breakpoint (`_narrow`, trip_detail_screen.dart).
    final narrow = MediaQuery.sizeOf(context).width < kRailBreakpoint;
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
    // Revisited-city chips are qualified by their VISIBLE start date, so this
    // view and trip detail name the same leg the same way (leg_ranges.dart:
    // promises about on-screen dates derive from the rendered ranges). The
    // raw ranges above stay the stay-coverage filter's input.
    //
    // Hoisted out of the chip call because the city headers below render these
    // same ranges: this screen has always COMPUTED them and only ever spent
    // them on the map's chip strip, so the dates a recipient wanted were one
    // local away the whole time.
    final visibleRanges = visibleLegRanges(trip);
    final legChips = mapLegChipEntries(l10n, legs, visibleRanges,
        labelText: _sharedLegLabel);
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
                  label: _sharedLegLabel(l10n, leg.label),
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
                        height: narrow ? 240 : 340,
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
                    for (final group in _groups(l10n, visibleRanges)) ...[
                      SharedCityHeader(
                        label: group.label,
                        range: group.dates?.range,
                        nights: group.dates?.nights,
                        narrow: narrow,
                      ),
                      SharedCityPlacesLine(
                          items: group.items, narrow: narrow),
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

/// A city's header: the primary-tinted pin, the city name in the display
/// register, and the leg's dates — a chip on the right where there is room,
/// stacked under the name where there is not.
///
/// This is trip detail's city header (`_cityHeader`, `itinerary_tab.dart`)
/// brought onto this screen, which never got that redesign and still led each
/// city with a bold sans label. Adopted rather than shared: trip detail's is a
/// State method wired to that screen's collapse toggle, hover-revealed refine
/// controls and a chip width measured across every group on the page, and it
/// resolves its own label through `groupLabelText` — which names the
/// unresolved-locality run "Other places" where this view deliberately says
/// "Places" ([_sharedLegLabel]). What is genuinely one rule is already shared
/// and stays shared: [visibleLegRanges] and `tripLegNights` are the same
/// derivation on both surfaces, so the two can differ in chrome but never in
/// what dates they claim.
///
/// Public because it is a named part of this screen and the screen's tests
/// anchor on it — a stable handle for "the city header", rather than walking
/// widget ancestry to find one, which is how the trip-detail header tests are
/// pinned and is the more brittle of the two.
class SharedCityHeader extends StatelessWidget {
  final String label;

  /// The leg's rendered date range, or null when the trip carries no dates —
  /// in which case the header renders the city name and nothing else. See
  /// [_legDates] for why there is no fallback.
  final String? range;

  /// The nights label, which owns its leading "· ". Kept as a value of its
  /// own rather than folded into [range] so a zero-night leg drops the middot
  /// with it, structurally — the two are always rendered as two Texts.
  final String? nights;

  final bool narrow;

  const SharedCityHeader({
    super.key,
    required this.label,
    required this.range,
    required this.nights,
    required this.narrow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Muted, not teal: a leg's dates are a fact about the row, not an action.
    // With the city name in the display face above, the range reading quietly
    // is what lets the name be the thing the eye lands on.
    final chipStyle = theme.textTheme.labelMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final r = range;
    // Narrow drops the dates OUT of the header row and stacks them under the
    // name: the chip is rigid, the label's Expanded is the only flex child, so
    // on a phone row the label absorbs the whole deficit and a city ellipsizes
    // to "Pra…". Columns are what the chip buys, and a phone has no room to
    // spend on them.
    final stack = narrow && r != null;
    return Padding(
      // The air goes ABOVE the heading, not below it — whitespace is zero-sum,
      // and a gap under a title pushes the title away from what it names.
      padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // The pin optically centers on the first line of a display-face
            // name, which sits taller than the 18px glyph.
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Icon(Icons.location_on,
                size: _pinSize, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: _pinGap),
          // The stacked meta line rides INSIDE this Expanded, never as a
          // second flex child: a sibling Flexible would split the free space
          // with the label and drag the chip off the right edge.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // A city is a SECTION HEADING, so it takes the display face
                  // at the register minted for exactly this — a heading that
                  // must not inflate into a hero.
                  style: AppTextStyles.sectionHeading(theme.textTheme),
                ),
                if (stack)
                  _MetaLine(range: r, nights: nights, style: chipStyle),
              ],
            ),
          ),
          if (r != null && !stack) ...[
            const SizedBox(width: AppSpacing.sm),
            MergeSemantics(
              // One utterance per chip ("Aug 24 – Aug 26 · 2 nights"), the
              // reading order a single Text would have had.
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _chipMaxWidth),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event,
                        size: _chipIconSize,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: _chipIconGap),
                    // The ONLY flex child in this Row, which is what makes the
                    // chip shrink-wrap to its text and still not overflow. A
                    // second Flexible here splits the bounded width EVENLY
                    // between the two regardless of what either needs, which
                    // rendered "Aug 24 – Au… · 1 night" — a truncated range
                    // beside a nights label with room to spare. Caught in the
                    // browser; a widget test could not have seen it.
                    Flexible(
                      child: Text(
                        r,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: chipStyle,
                      ),
                    ),
                    // Two Texts, never "$range · $nights" — see [_legDates].
                    if (nights != null) ...[
                      const SizedBox(width: _chipInnerGap),
                      ConstrainedBox(
                        // Intrinsic width, so the nights takes what it needs
                        // and the range absorbs any deficit. Bounded only for
                        // the pathological case: at an extreme text scale a
                        // nights label alone could exceed the whole chip.
                        constraints: const BoxConstraints(
                            maxWidth: _chipMaxWidth -
                                _chipIconSize -
                                _chipIconGap -
                                _chipInnerGap),
                        child: Text(
                          nights!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: chipStyle,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The narrow city header's second line: "Aug 24 – Aug 26 · 2 nights".
///
/// Carries no calendar icon — the pin beside it already anchors the row, and a
/// second glyph on a phone is the noise this pass removes. Both parts are
/// Flexible so an extreme text scale ellipsizes inside the label column
/// instead of overflowing it.
class _MetaLine extends StatelessWidget {
  final String range;
  final String? nights;
  final TextStyle? style;

  const _MetaLine(
      {required this.range, required this.nights, required this.style});

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              range,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          // The middot lives in `tripLegNights`, so a zero-night leg loses it
          // with this whole branch rather than through a format conditional.
          if (nights != null) ...[
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                nights!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One city's places as a single run of names, replacing the per-place rows
/// this view used to stack under each city.
///
/// The separator is "·" and not "|" for a reason that is in the data: a place
/// name may already carry a pipe — "SOVA | Modern Czech Cuisine" — and a pipe
/// separator would read as two restaurants. Beyond [_placesCapWide] /
/// [_placesCapNarrow] names the run caps with "+N more", the same overflow
/// grammar the travel atlas's `citiesLabel` speaks, so the screen has one way
/// of saying "and some others" rather than two.
///
/// One [Text.rich] rather than a Wrap of chips: names have to be able to wrap
/// MID-RUN like prose, and the separators have to sit at the muted weight
/// between them.
///
/// Public for the same reason as [SharedCityHeader] — the screen's tests need
/// a stable handle on "the places under a city".
class SharedCityPlacesLine extends StatelessWidget {
  final List<ItineraryItem> items;
  final bool narrow;

  const SharedCityPlacesLine(
      {super.key, required this.items, required this.narrow});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final cap = narrow ? _placesCapNarrow : _placesCapWide;
    final shown = items.length > cap ? items.take(cap).toList() : items;
    final rest = items.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(
          left: _pinColumnWidth, bottom: AppSpacing.xs),
      child: Text.rich(
        TextSpan(
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) TextSpan(text: ' · ', style: muted),
              TextSpan(text: shown[i].name),
            ],
            if (rest > 0) ...[
              TextSpan(text: ' · ', style: muted),
              TextSpan(text: l10n.sharedCityMorePlaces(rest), style: muted),
            ],
          ],
        ),
      ),
    );
  }
}
