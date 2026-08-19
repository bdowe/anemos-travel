// The trip detail map band (specs/trip-detail-extract): the rounded map
// card shared by the wide pinned header and the phone scroll-away preview,
// plus the sliver slot that hosts them. Verbatim lift out of
// trip_detail_screen.dart so wave 2 can redesign band height and the
// band↔tab-bar seam without the god-screen. Zero visual, zero behavior
// change: every screen interaction arrives as a constructor callback.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../models/trip.dart';
import '../../providers/home_overlay_provider.dart';
import '../../screens/trip_detail_derivation.dart';
import '../../screens/trip_map_screen.dart';
import '../../theme/spacing.dart';
import '../app_map.dart';
import '../map_leg_chips.dart';
import '../trip_map.dart';

/// Wide pinned-header extent: top gap + map + bottom gap (the phone layout's
/// preview is [mapBandHeightNarrow] and scrolls away instead).
const double mapBandHeaderHeight = 12 + 340 + 12;

/// Map card height on phones, where the map scrolls away instead of
/// pinning (a preview — the full-screen map is one tap away).
const double mapBandHeightNarrow = 180;

/// The band's sliver slot, shared by both layouts: pinned under the top
/// chrome on wide, a fixed-height scroll-away preview on phones. The pinned
/// branch's delegate stays the screen's own (it also pins the tab row), so
/// it arrives as [pinnedDelegateBuilder]; the band's heights live HERE.
Widget tripDetailMapBandSliver({
  required bool pinned,
  required double gutter,
  required Color backgroundColor,
  required Widget Function(bool expandable) cardBuilder,
  required SliverPersistentHeaderDelegate Function({
    required double height,
    required Color backgroundColor,
    required EdgeInsetsGeometry padding,
    required Widget child,
  }) pinnedDelegateBuilder,
}) {
  if (pinned) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: pinnedDelegateBuilder(
        height: mapBandHeaderHeight,
        backgroundColor: backgroundColor,
        padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 12),
        child: cardBuilder(false),
      ),
    );
  }
  return SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 12),
      child: SizedBox(height: mapBandHeightNarrow, child: cardBuilder(true)),
    ),
  );
}

/// The rounded map card itself. When [TripDetailMapBand.expandable], the map
/// is a static preview whose single tap target opens the full-screen map.
class TripDetailMapBand extends StatelessWidget {
  final Trip trip;
  final TripDerivation derivation;
  final bool expandable;
  final ValueNotifier<String?> focusedLegKey;
  final ValueNotifier<int?> selectedPosition;
  final String? homeAirport;
  final bool isOffline;
  final bool readOnly;
  final Map<int, String> segmentLabels;
  final void Function(int? day) onAddPlace;
  final void Function(String groupKey) onRevealGroup;
  final void Function(String groupKey) onRevealCityHeader;
  final void Function(String? legKey) onSetFocusedLeg;
  final VoidCallback onOpenFullMap;
  final void Function(String message) onShowSnack;
  final String? Function(TripDerivation) clampLegKey;

  const TripDetailMapBand({
    super.key,
    required this.trip,
    required this.derivation,
    required this.expandable,
    required this.focusedLegKey,
    required this.selectedPosition,
    required this.homeAirport,
    required this.isOffline,
    required this.readOnly,
    required this.segmentLabels,
    required this.onAddPlace,
    required this.onRevealGroup,
    required this.onRevealCityHeader,
    required this.onSetFocusedLeg,
    required this.onOpenFullMap,
    required this.onShowSnack,
    required this.clampLegKey,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final trip = this.trip;
    final expandable = this.expandable;
    final derivation = this.derivation;
    final endpoints = derivation.homeLegEndpoints;
    final legChips = derivation.legChips;
    // The strip and focus exist only with ≥2 legs — below that the
    // destination-overview mode never engages, so "All" and "the one leg"
    // would draw the identical map.
    final hasChips = legChips.length >= 2;
    String labelFor(String key) {
      for (final c in legChips) {
        if (c.key == key) return c.label;
      }
      return key;
    }

    // Focus + selection live in ValueNotifiers: this builder — not the whole
    // screen — is what a leg-chip tap or pin/row selection rebuilds. The
    // leg-filtered lists come from the derivation's lazy per-leg caches, so
    // a selection-only rebuild passes TripMap the identical lists and its
    // marker cache skips re-clustering.
    final card = ListenableBuilder(
      listenable: Listenable.merge([focusedLegKey, selectedPosition]),
      builder: (context, _) {
        final focusKey = clampLegKey(derivation);
        // Consumer, not the screen's ref: homeOverlayFor watches the
        // home-airport resolution provider, and that watch belongs to the
        // map subtree — resolution landing must not rebuild the screen.
        Widget map = Consumer(
          builder: (context, ref, _) {
            final candidates = homeOverlayFor(
              ref,
              homeAirport: homeAirport,
              travelMode: trip.travelMode,
              tripOrigin: trip.origin,
              tripOriginAirport: trip.originAirport,
              tripReturnAirport: trip.returnAirport,
              focusedLegIndex:
                  focusKey == null ? null : derivation.legIndexOf(focusKey),
              legCount: derivation.legs.length,
              firstCityPoint: endpoints.first,
              lastCityPoint: endpoints.last,
            );
            // !expandable == _mapPinned at both _mapCard call sites, so the
            // wide default rides the same slot-width answer as the layout.
            final showHome = homeOverlayVisible(
              choice: ref.watch(homeOverlayChoiceProvider),
              wideLayout: !expandable,
            );
            return TripMap(
              items: derivation.legFilteredItems(focusKey),
              accommodations: derivation.legFilteredStays(focusKey),
              destinations:
                  focusKey == null ? derivation.mapDestinations : null,
              selectedPosition: selectedPosition.value,
              // Unfiltered by leg: TripMap's position+1 adjacency guard
              // already keeps labels within a city.
              segmentLabels: segmentLabels,
              home: showHome ? candidates : const [],
              homeShown: showHome,
              // Narrow preview (expandable) deliberately gets no toggle:
              // interactive:false suppresses the controls anyway, and the
              // full-screen map — one tap away — carries it.
              onToggleHome: (expandable || candidates.isEmpty)
                  ? null
                  : () => ref
                      .read(homeOverlayChoiceProvider.notifier)
                      .setShown(!showHome),
              fitSignature: focusKey,
              // Keep fitted markers clear of the chip row overlaid below.
              topOverlayInset: hasChips ? MapLegChips.mapTopInset : 0,
              interactive: !expandable,
              emptyLabel: focusKey == null
                  ? l10n.tripNoMappedPlaces
                  : l10n.tripNoPlacesInLeg(labelFor(focusKey)),
              // The preview absorbs pointers, so its empty-state add-place
              // hint and CTA would invite an action it can't take (tapping
              // opens the full-screen map, which has both); dropping them
              // also keeps the empty state inside the 180px preview card.
              // The pinned "+ Add place" button sits right below anyway.
              emptyMessage:
                  (expandable || isOffline) ? null : l10n.tripAddPlaceMapHint,
              emptyAction: (expandable || isOffline || readOnly)
                  ? null
                  : FilledButton.tonalIcon(
                      onPressed: () =>
                          onAddPlace(derivation.dayForLeg(focusKey)),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l10n.tripAddPlace),
                    ),
              onPinTap: expandable
                  ? null
                  : (pos) {
                      final it =
                          trip.items!.firstWhere((i) => i.position == pos);
                      selectedPosition.value = pos;
                      // The highlighted row can only be seen if its run
                      // renders: un-collapse the tapped item's group in
                      // case the user closed it. Never a focus write —
                      // that would refit the camera out from under the
                      // zoom-to-pin move (the invariant holds by
                      // construction: nothing here touches
                      // focusedLegKey). Selection itself is
                      // notifier-driven, so setState only on a real
                      // un-collapse.
                      final d = derivation;
                      final groupKey =
                          d.groupKeyForLeg(d.legKeyOfPosition(pos));
                      if (groupKey != null) onRevealGroup(groupKey);
                      onShowSnack(it.name);
                    },
              // Region-pin navigation (All overview only — that's the only
              // mode destination pins render in): scroll the list to the
              // region's group. Deliberately NO focus write: focusing
              // would swap the map to per-item pins and delete the very
              // pins under the pointer; the camera must not move either.
              onDestinationTap: expandable
                  ? null // phone preview: AbsorbPointer'd, tap opens full map
                  : (legKey) {
                      final d = derivation;
                      final groupKey = d.groupKeyForLeg(legKey);
                      if (groupKey == null) return; // lens dropped the leg
                      onRevealGroup(groupKey);
                      // Under a bookings/budget lens no header builds and
                      // the scroll no-ops harmlessly (the chip-tap stance:
                      // no lens exit).
                      onRevealCityHeader(groupKey);
                    },
              onExpand: expandable ? null : onOpenFullMap,
            );
          },
        );
        if (expandable) {
          map = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpenFullMap,
            child: AbsorbPointer(child: map),
          );
        }
        return ClipRRect(
          borderRadius: AppRadius.lgAll,
          child: Stack(
            children: [
              Positioned.fill(child: map),
              // Above the map's gesture layer, so chip taps and row scrolls
              // never pan the map.
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: MapLegChips(
                  legs: legChips,
                  selected: focusKey,
                  mappedLegKeys: derivation.mappedLegKeys,
                  onSelected: onSetFocusedLeg,
                ),
              ),
              if (expandable)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: MapControlButton(
                    icon: Icons.fullscreen,
                    tooltip: l10n.tripExpandMap,
                    onTap: onOpenFullMap,
                  ),
                ),
            ],
          ),
        );
      },
    );
    // Repaint-isolate the card: on the wide layout it sits pinned over the
    // scrolling itinerary, and without a boundary its picture (card chrome +
    // chip strip — flutter_map keeps its own internal boundary) is
    // re-recorded every scroll frame. The boundary also keeps tap-time card
    // rebuilds from dirtying the page layer. Inside the method so both call
    // sites (pinned wide band, scroll-away phone card) are covered.
    return RepaintBoundary(child: card);
  }
}
