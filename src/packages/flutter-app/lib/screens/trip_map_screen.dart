import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../providers/flights_provider.dart';
import '../utils/snack.dart';
import '../utils/travel_mode.dart';
import '../widgets/app_map.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/map_leg_chips.dart';
import '../widgets/trip_map.dart';

/// Builds the journey-endpoint overlay for a trip-map surface: the airports
/// this trip departs from and returns into, as pins with dashed legs. Usually
/// one entry — most trips leave and return through the same airport — and two
/// when they differ (out of ALB, home into EWR). Empty while the IATA →
/// coordinate lookup is pending or failed, and each end resolves INDEPENDENTLY:
/// one code that resolves still draws its pin when the other doesn't.
///
/// The outbound leg belongs to the FIRST city leg and the return leg to the
/// LAST, so a mid-trip city focus shows no orphan pin ([focusedLegIndex] null =
/// All shows both; a stale key resolved to -1 shows neither, which is safe
/// because a stale focus also empties the item list). Shared by the full-screen
/// map and the inline trip-detail card so both surfaces gate identically.
List<TripMapHome> homeOverlayFor(
  WidgetRef ref, {
  required String? homeAirport,
  required String? travelMode,
  required String? tripOrigin,
  required String? tripOriginAirport,
  required String? tripReturnAirport,
  required int? focusedLegIndex, // null = All
  required int legCount,
  required LatLng? firstCityPoint,
  required LatLng? lastCityPoint,
}) {
  // A saved home *airport* only says where this traveler flies from. On a
  // stated ground trip it is not the origin — someone driving to Montreal from
  // upstate New York does not set out from Newark — so drawing a leg from it
  // would invent a journey the trip never described. Say nothing instead.
  if (groundTravelMode(travelMode) != null) return const [];

  /// The code to pin for one end of the journey, or null when we hold no
  /// coordinates for it. Mirrors _deriveTodos' label ladder rung for rung
  /// (trip_detail_screen.dart), minus the free-text rung: an origin stated in
  /// words ENDS the ladder — the saved airport is then known to be the wrong
  /// start, and "Lake George, NY" has no coordinates to pin. The booking legs
  /// still carry it by name.
  String? codeFor(String? tripAirport) {
    final own = tripAirport?.trim();
    if (own != null && own.isNotEmpty) return own.toUpperCase();
    if ((tripOrigin?.trim() ?? '').isNotEmpty) return null;
    final saved = homeAirport?.trim();
    return (saved == null || saved.isEmpty) ? null : saved.toUpperCase();
  }

  LatLng? pointFor(String? code) {
    if (code == null) return null;
    final p = ref.watch(homeAirportPointProvider(code)).valueOrNull;
    return p == null ? null : LatLng(p.lat, p.lng);
  }

  final departureCode = codeFor(tripOriginAirport);
  final arrivalCode = codeFor(tripReturnAirport);
  final outboundTo =
      (focusedLegIndex == null || focusedLegIndex == 0) ? firstCityPoint : null;
  final returnFrom = (focusedLegIndex == null || focusedLegIndex == legCount - 1)
      ? lastCityPoint
      : null;

  // One airport for both directions — the common case, and byte-for-byte the
  // single pin this drew before a trip could have two.
  if (departureCode != null && departureCode == arrivalCode) {
    final point = pointFor(departureCode);
    if (point == null || (outboundTo == null && returnFrom == null)) {
      return const [];
    }
    return [
      TripMapHome(
        point: point,
        label: departureCode,
        outboundTo: outboundTo,
        returnFrom: returnFrom,
      ),
    ];
  }

  final out = <TripMapHome>[];
  final departurePoint = pointFor(departureCode);
  if (departurePoint != null && outboundTo != null) {
    out.add(TripMapHome(
      point: departurePoint,
      label: departureCode!,
      outboundTo: outboundTo,
      kind: TripMapHomeKind.departure,
    ));
  }
  final arrivalPoint = pointFor(arrivalCode);
  if (arrivalPoint != null && returnFrom != null) {
    out.add(TripMapHome(
      point: arrivalPoint,
      label: arrivalCode!,
      returnFrom: returnFrom,
      kind: TripMapHomeKind.arrival,
    ));
  }
  return out;
}

/// Full-screen interactive trip map, pushed from the trip detail screen on
/// phones (where the inline map is a static tap-to-expand preview). Pushed as
/// a `fullscreenDialog` route so the framework provides the localized close
/// button.
///
/// Leg focus is resolved through the [itemsForLeg]/[staysForLeg] closures so
/// the parent's leg→night stay math stays in one place; the closures read
/// the parent's live trip field, but a silent refresh while this screen is
/// open only shows up after the next chip tap rebuilds it — acceptable
/// staleness for a modal map.
class TripMapScreen extends ConsumerStatefulWidget {
  final String title;

  /// Items/stays to plot for a leg-chip selection (null = All), supplied by
  /// the trip detail screen (specs/map-city-focus).
  final List<ItineraryItem> Function(String? legKey) itemsForLeg;
  final List<Accommodation> Function(String? legKey) staysForLeg;

  final Map<int, String> segmentLabels;

  /// One chip per full-itinerary leg, visit order, labels display-ready —
  /// the parent derivation's `legChips`. Frozen at push time.
  final List<({String key, String label, String? qualifier})> legChips;
  final Set<String>? mappedLegKeys;

  /// Initial leg-chip selection; chip taps also report through
  /// [onLegSelected] so the inline map's chips stay in sync live (a pop
  /// result can't distinguish "All" from "dismissed" — null is a legal
  /// value).
  final String? initialLegKey;
  final ValueChanged<String?> onLegSelected;

  /// Opens the add-place flow for the current leg focus. Null (offline /
  /// read-only) hides the empty state's CTA and hint.
  final void Function(String? legKey)? onAddPlace;

  /// The viewer's saved home-airport IATA code; with the trip's first/last
  /// city coordinates it draws the journey's home legs (owner surfaces only —
  /// shared views pass nothing). Null = no home overlay.
  final String? homeAirport;

  /// The trip's `travel_mode`. A stated ground mode suppresses the home-airport
  /// overlay entirely (see [homeOverlayFor]).
  final String? travelMode;

  /// The trip's stated origin (free text); like a ground [travelMode], its
  /// presence suppresses the overlay — there are no coordinates for a place
  /// name. An airport below outranks it.
  final String? tripOrigin;

  /// The trip's own departure/return airports (IATA), which may differ from
  /// each other and from [homeAirport]. Null = this trip states none.
  final String? tripOriginAirport;
  final String? tripReturnAirport;
  final LatLng? firstCityPoint;
  final LatLng? lastCityPoint;

  /// Trip-overview destination pins, derived by the parent from the full
  /// itinerary. Shown only under the All chip (a city focus flips back to
  /// per-item pins). Frozen at push time like the home-leg endpoints — a
  /// silent refresh shows up on the next open.
  final List<TripMapDestination>? destinations;

  const TripMapScreen({
    super.key,
    required this.title,
    required this.itemsForLeg,
    required this.staysForLeg,
    required this.segmentLabels,
    required this.legChips,
    required this.onLegSelected,
    this.mappedLegKeys,
    this.initialLegKey,
    this.onAddPlace,
    this.homeAirport,
    this.travelMode,
    this.tripOrigin,
    this.tripOriginAirport,
    this.tripReturnAirport,
    this.firstCityPoint,
    this.lastCityPoint,
    this.destinations,
  });

  @override
  ConsumerState<TripMapScreen> createState() => _TripMapScreenState();
}

class _TripMapScreenState extends ConsumerState<TripMapScreen> {
  late String? _legKey = widget.initialLegKey;
  int? _selectedPosition;

  List<TripMapHome> _homeOverlay() => homeOverlayFor(
        ref,
        homeAirport: widget.homeAirport,
        travelMode: widget.travelMode,
        tripOrigin: widget.tripOrigin,
        tripOriginAirport: widget.tripOriginAirport,
        tripReturnAirport: widget.tripReturnAirport,
        focusedLegIndex: _legKey == null
            ? null
            : widget.legChips.indexWhere((c) => c.key == _legKey),
        legCount: widget.legChips.length,
        firstCityPoint: widget.firstCityPoint,
        lastCityPoint: widget.lastCityPoint,
      );

  String _labelFor(String key) {
    for (final c in widget.legChips) {
      if (c.key == key) return c.label;
    }
    return key;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = widget.itemsForLeg(_legKey);
    final onAddPlace = widget.onAddPlace;
    // Escape closes the map. Two layers on purpose: this shortcut rides the
    // key-event focus chain, catching Escape while anything in the Scaffold
    // holds focus (the map autofocuses) — the framework's own
    // Escape→DismissIntent path is a dead end from there, because Scaffold
    // maps DismissIntent to its drawer-close action and the intent stops at
    // the nearest type match even while disabled. When nothing in the body
    // holds focus (pin-less leg: the empty state drops the map and its focus
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
            // empty state, so once a leg has a single pin the full-screen map
            // would otherwise force a round-trip back to trip detail to add
            // the next place. Null onAddPlace (offline / read-only) hides it.
            if (onAddPlace != null)
              IconButton(
                tooltip: l10n.tripAddPlace,
                onPressed: () => onAddPlace(_legKey),
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
                  accommodations: widget.staysForLeg(_legKey),
                  destinations: _legKey == null ? widget.destinations : null,
                  selectedPosition: _selectedPosition,
                  segmentLabels: widget.segmentLabels,
                  home: _homeOverlay(),
                  fitSignature: _legKey,
                  // Keep fitted markers clear of the chip row overlaid below.
                  topOverlayInset: widget.legChips.length >= 2
                      ? MapLegChips.mapTopInset
                      : 0,
                  emptyLabel: _legKey == null
                      ? l10n.tripNoMappedPlaces
                      : l10n.tripNoPlacesInLeg(_labelFor(_legKey!)),
                  emptyMessage:
                      onAddPlace == null ? null : l10n.tripAddPlaceMapHint,
                  emptyAction: onAddPlace == null
                      ? null
                      : FilledButton.tonalIcon(
                          onPressed: () => onAddPlace(_legKey),
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
                  // A region pin tap focuses that city in place — the
                  // chip-equivalent (there is no list here to scroll to):
                  // the map flips from the overview to the leg's item pins,
                  // and the report-back lets trip detail pre-scroll the
                  // list behind the modal so closing lands on the region.
                  onDestinationTap: (legKey) {
                    setState(() {
                      _legKey = legKey;
                      _selectedPosition = null;
                    });
                    widget.onLegSelected(legKey);
                  },
                ),
              ),
              // Above the map's gesture layer, so chip taps and row scrolls never
              // pan the map.
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: MapLegChips(
                  legs: widget.legChips,
                  selected: _legKey,
                  mappedLegKeys: widget.mappedLegKeys,
                  onSelected: (k) {
                    // Clear the pin selection with the focus change: a
                    // lingering selection would suppress later content
                    // refits and keep a ghost highlight from another leg.
                    setState(() {
                      _legKey = k;
                      _selectedPosition = null;
                    });
                    widget.onLegSelected(k);
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
