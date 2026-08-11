import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../providers/flights_provider.dart';
import '../utils/snack.dart';
import '../widgets/app_map.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/map_day_chips.dart';
import '../widgets/trip_map.dart';

/// Builds the home-airport overlay for a trip-map surface, or null while the
/// IATA → coordinate lookup is pending / failed (the map simply omits the
/// legs; the provider watch rebuilds when it resolves). The outbound leg
/// belongs to day 1 and the return leg to the last day, so mid-trip day
/// chips show no orphan home pin. Shared by the full-screen map and the
/// inline trip-detail card so both surfaces gate identically.
TripMapHome? homeOverlayFor(
  WidgetRef ref, {
  required String? homeAirport,
  required int? day, // null = All
  required int dayCount, // the surface's mapDayCount
  required LatLng? firstCityPoint,
  required LatLng? lastCityPoint,
}) {
  final code = homeAirport;
  if (code == null || code.isEmpty) return null;
  final point = ref.watch(homeAirportPointProvider(code)).valueOrNull;
  if (point == null) return null;
  final outboundTo = (day == null || day == 1) ? firstCityPoint : null;
  final returnFrom = (day == null || day == dayCount) ? lastCityPoint : null;
  if (outboundTo == null && returnFrom == null) return null;
  return TripMapHome(
    point: LatLng(point.lat, point.lng),
    label: code,
    outboundTo: outboundTo,
    returnFrom: returnFrom,
  );
}

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
class TripMapScreen extends ConsumerStatefulWidget {
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

  /// The viewer's saved home-airport IATA code; with the trip's first/last
  /// city coordinates it draws the journey's home legs (owner surfaces only —
  /// shared views pass nothing). Null = no home overlay.
  final String? homeAirport;
  final LatLng? firstCityPoint;
  final LatLng? lastCityPoint;

  /// Trip-overview destination pins, derived by the parent from the full
  /// itinerary. Shown only under the All chip (day chips flip back to
  /// per-item pins). Frozen at push time like the home-leg endpoints — a
  /// silent refresh shows up on the next open.
  final List<TripMapDestination>? destinations;

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
    this.homeAirport,
    this.firstCityPoint,
    this.lastCityPoint,
    this.destinations,
  });

  @override
  ConsumerState<TripMapScreen> createState() => _TripMapScreenState();
}

class _TripMapScreenState extends ConsumerState<TripMapScreen> {
  late int? _day = widget.initialDay;
  int? _selectedPosition;

  TripMapHome? _homeOverlay() => homeOverlayFor(
        ref,
        homeAirport: widget.homeAirport,
        day: _day,
        dayCount: widget.dayCount,
        firstCityPoint: widget.firstCityPoint,
        lastCityPoint: widget.lastCityPoint,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = widget.itemsForDay(_day);
    final onAddPlace = widget.onAddPlace;
    // Escape closes the map. Two layers on purpose: this shortcut rides the
    // key-event focus chain, catching Escape while anything in the Scaffold
    // holds focus (the map autofocuses) — the framework's own
    // Escape→DismissIntent path is a dead end from there, because Scaffold
    // maps DismissIntent to its drawer-close action and the intent stops at
    // the nearest type match even while disabled. When nothing in the body
    // holds focus (pin-less day: the empty state drops the map and its focus
    // node), the key skips this node and the route's own dismiss action pops
    // instead — enabled by `barrierDismissible: true` at the push site.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        // The strip the bottom SafeArea leaves below the map reads as part of
        // the space-dark map canvas instead of a bare scaffold gap.
        backgroundColor: appMapBackground,
        appBar: GradientAppBar(
          // Multi-city titles ("Barcelona, Madrid & 3 more") must ellipsize —
          // the fullscreenDialog close button already eats leading width.
          title:
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
                  destinations: _day == null ? widget.destinations : null,
                  selectedPosition: _selectedPosition,
                  segmentLabels: widget.segmentLabels,
                  home: _homeOverlay(),
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
      ),
    );
  }
}
