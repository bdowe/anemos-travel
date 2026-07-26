import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../utils/snack.dart';
import '../widgets/app_map.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/map_day_chips.dart';
import '../widgets/trip_map.dart';

/// Full-screen interactive trip map, pushed from the trip detail screen on
/// phones (where the inline map is a static tap-to-expand preview). Pushed as
/// a `fullscreenDialog` route so the framework provides the localized close
/// button.
///
/// Day filtering is resolved through the [itemsForDay]/[staysForDay] closures
/// so the parent's day→night stay math stays in one place; the closures read
/// the parent's live trip field, but a silent refresh while this screen is
/// open only shows up after the next chip tap rebuilds it — acceptable
/// staleness for a modal map.
class TripMapScreen extends StatefulWidget {
  final String title;

  /// Items/stays to plot for a day-chip selection (null = All), supplied by
  /// the trip detail screen.
  final List<ItineraryItem> Function(int? day) itemsForDay;
  final List<Accommodation> Function(int? day) staysForDay;

  final Map<int, String> segmentLabels;
  final int dayCount;
  final Set<int>? mappedDays;

  /// Initial day-chip selection; chip taps also report through
  /// [onDaySelected] so the inline map's chips stay in sync live (a pop
  /// result can't distinguish "All" from "dismissed" — null is a legal
  /// value).
  final int? initialDay;
  final ValueChanged<int?> onDaySelected;

  /// Opens the add-place flow for the current day selection. Null (offline /
  /// read-only) hides the empty state's CTA and hint.
  final void Function(int? day)? onAddPlace;

  const TripMapScreen({
    super.key,
    required this.title,
    required this.itemsForDay,
    required this.staysForDay,
    required this.segmentLabels,
    required this.dayCount,
    required this.onDaySelected,
    this.mappedDays,
    this.initialDay,
    this.onAddPlace,
  });

  @override
  State<TripMapScreen> createState() => _TripMapScreenState();
}

class _TripMapScreenState extends State<TripMapScreen> {
  late int? _day = widget.initialDay;
  int? _selectedPosition;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = widget.itemsForDay(_day);
    final onAddPlace = widget.onAddPlace;
    return Scaffold(
      // The strip the bottom SafeArea leaves below the map reads as part of
      // the space-dark map canvas instead of a bare scaffold gap.
      backgroundColor: appMapBackground,
      appBar: GradientAppBar(
        // Multi-city titles ("Barcelona, Madrid & 3 more") must ellipsize —
        // the fullscreenDialog close button already eats leading width.
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          // Persistent add affordance: the on-map CTA only exists in the
          // empty state, so once a day has a single pin the full-screen map
          // would otherwise force a round-trip back to trip detail to add
          // the next place. Null onAddPlace (offline / read-only) hides it.
          if (onAddPlace != null)
            IconButton(
              tooltip: l10n.tripAddPlace,
              onPressed: () => onAddPlace(_day),
              icon: const Icon(Icons.add_location_alt_outlined),
            ),
        ],
      ),
      // Root-navigator fullscreenDialog: without a bottom SafeArea the
      // zoom/reset column and the attribution button sit under the iOS home
      // indicator. Top stays with the app bar.
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: TripMap(
                items: items,
                accommodations: widget.staysForDay(_day),
                selectedPosition: _selectedPosition,
                segmentLabels: widget.segmentLabels,
                fitSignature: _day,
                // Keep fitted markers clear of the chip row overlaid below.
                topOverlayInset:
                    widget.dayCount > 0 ? MapDayChips.mapTopInset : 0,
                emptyLabel: _day == null
                    ? l10n.tripNoMappedPlaces
                    : l10n.tripNoPlacesOnDay(_day!),
                emptyMessage:
                    onAddPlace == null ? null : l10n.tripAddPlaceMapHint,
                emptyAction: onAddPlace == null
                    ? null
                    : FilledButton.tonalIcon(
                        onPressed: () => onAddPlace(_day),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(l10n.tripAddPlace),
                      ),
                onPinTap: (pos) {
                  setState(() => _selectedPosition = pos);
                  for (final it in items) {
                    if (it.position == pos) {
                      showSnack(context, it.name);
                      break;
                    }
                  }
                },
              ),
            ),
            // Above the map's gesture layer, so chip taps and row scrolls never
            // pan the map.
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: MapDayChips(
                dayCount: widget.dayCount,
                selected: _day,
                mappedDays: widget.mappedDays,
                onSelected: (d) {
                  setState(() => _day = d);
                  widget.onDaySelected(d);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
