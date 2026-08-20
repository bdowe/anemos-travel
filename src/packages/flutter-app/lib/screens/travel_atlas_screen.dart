import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/trips_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import '../utils/trip_list_insights.dart';
import '../widgets/app_map.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../widgets/travel_footprint_parts.dart';
import 'trip_detail_screen.dart';

/// Handles for the atlas's two colophon groups and its index. Locale-free on
/// purpose (the [kTraveledStatsKey] convention): "is the traveled group on
/// screen?" is the invariant, and a test that asked by label would answer it
/// differently in Spanish. Deliberately NOT the trips-list card's keys — two
/// surfaces, two handles, so neither test can accidentally answer about the
/// other.
const kAtlasTraveledStatsKey = ValueKey('travelAtlas.stats.traveled');
const kAtlasPlannedStatsKey = ValueKey('travelAtlas.stats.planned');
const kAtlasIndexKey = ValueKey('travelAtlas.index');

/// The plate's height below the wide seam.
///
/// Measured, not picked between the wireframe's 280 and `_GuideMap`'s shipped
/// 240 — and measured **in the running app**, because the thing being measured
/// is where text lands, and widget tests lay out with Flutter's fixed-width
/// test font rather than Inter. A number taken from a widget test would not be
/// a number about this app.
///
/// The binding case is the smallest phone this app supports (375×667) carrying
/// the tallest chrome this screen can have — the year chip row above a
/// colophon rendering BOTH groups — and, crucially, **under the shell's
/// [NavigationBar]**, whose 80px means the fold sits ~80px above the viewport
/// floor. Each index row is 49 tall, so the candidates differ only in what
/// survives that fold:
///
///   * **280** — the heading, with the first row's text under the bar.
///   * **256** — the heading and one row, nothing after it.
///   * **240** — the heading and one whole row, the second beginning right at
///     the bar: the most a phone this small has room to promise.
///
/// So 240 — which is also, independently, the height this app already ships
/// for an interactive map inside a scrolling column (`_GuideMap`), so the
/// atlas introduces no third map size. It is genuinely tight at 667pt and
/// comfortable everywhere else: a 390×844 phone shows the heading and FOUR
/// whole rows with a fifth cut by the bar. Going shorter to buy the smallest
/// phone a second row would cost every other phone the map room this screen
/// exists to give.
///
/// The screen's test pins this constant and the order of what follows it —
/// both font-independent. The fold numbers above are browser measurements and
/// deliberately are not asserted anywhere: a pixel claim about text in a
/// widget test would be a claim about the test font.
const double kAtlasPlateHeight = 240;

/// The travel atlas: everywhere this traveler has been, given room.
///
/// The "See all" destination of the trips list's "Your travels" section. The
/// band up there stays exactly what PR #488 made it — a 140px static plate
/// closing the page — because the case for this screen is **size and focus**,
/// not impossibility: a 140px band is a thumbnail of the whole planet, and no
/// gesture policy fixes that. Growing the band instead would mean promoting
/// the retrospective above the plans, which is the ordering PR #488 settled.
///
/// Three elements, top to bottom:
///
///  1. **The plate** — satellite tiles under the same footprint pins, pan and
///     zoom, and **no text on the image**. That last one is a brand
///     requirement rather than a preference: text on satellite would need a
///     scrim, and `heroScrim` over imagery is a teal-tinted photo — a named
///     instant finding. With the caption on paper below, the question does
///     not arise, which is also where a journal actually puts a plate caption.
///  2. **The colophon** — [travelStats] unchanged, traveled/planned split
///     intact, rendered by the same [TravelStatGroup] the band uses. A group
///     whose trip count is zero still doesn't render.
///  3. **The index** — [atlasRows]: **past trips only** ([tripIsPast]),
///     complete, newest first, no cap. Planned trips stay on the map as hollow
///     pins and stay out of here: the map is *everywhere*, the index is
///     *where you've been*.
///
/// Route arcs are deliberately absent. [CityPin] carries `{city, lat, lng}` —
/// no ordinal, no date, no trip id — and the server's hub lateral is a deduped
/// set in first-appearance order, so a round trip's return leg is
/// structurally unrepresentable. Arcs need a server change to the list
/// lateral and are out of scope.
class TravelAtlasScreen extends ConsumerStatefulWidget {
  const TravelAtlasScreen({super.key});

  @override
  ConsumerState<TravelAtlasScreen> createState() => _TravelAtlasScreenState();
}

class _TravelAtlasScreenState extends ConsumerState<TravelAtlasScreen> {
  /// Width at which the index moves beside the plate instead of under it, and
  /// the width it takes there. 900 is this app's established side-by-side seam
  /// (the trip detail docks its chat panel at exactly 900, in a 400px column);
  /// matching both means the atlas's wide layout is the one the app already
  /// teaches rather than a third answer.
  static const double _wideSeam = 900;
  static const double _sideColumnWidth = 400;

  /// The selected year, or null for "All time". Screen state rather than a
  /// provider: it is a lens on this screen, not a fact about the account, and
  /// leaving the atlas should forget it.
  int? _year;

  @override
  void initState() {
    super.initState();
    // Deep-link arrival (/atlas in the address bar, a refresh) reaches this
    // screen with the trips list never fetched. Pushed arrivals find it
    // already loaded and skip the call.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = ref.read(tripsProvider);
      if (state.trips.isEmpty && !state.loading) {
        ref.read(tripsProvider.notifier).loadTrips();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(tripsProvider);
    // The title is the section's own string, not a second one: the door and
    // the page behind it can never end up calling the place two names.
    Widget scaffold(Widget body) => Scaffold(
          appBar: GradientAppBar(title: l10n.tripsListYourTravels),
          body: body,
        );

    if (state.loading && state.trips.isEmpty) {
      return scaffold(const Center(child: CircularProgressIndicator()));
    }
    if (state.error != null && state.trips.isEmpty) {
      return scaffold(EmptyState(
        icon: Icons.cloud_off,
        title: l10n.tripsListErrorTitle,
        message: l10n.tripsListErrorMessage,
        actions: [
          FilledButton(
            onPressed: () => ref.read(tripsProvider.notifier).loadTrips(),
            child: Text(l10n.commonRetry),
          ),
        ],
      ));
    }

    final now = DateTime.now();
    final trips = state.trips;
    final rows = atlasRows(trips, now);

    // Only reachable by URL: the door is gated on 2+ finished trips precisely
    // so nobody navigates into a retrospective of a past that hasn't happened.
    // The way out is the way the history gets here (specs/log-past-trip).
    if (rows.isEmpty) {
      return scaffold(EmptyState(
        icon: Icons.public,
        title: l10n.travelAtlasEmptyTitle,
        message: l10n.travelAtlasEmptyMessage,
        actions: [
          OutlinedButton.icon(
            onPressed: () => openLogTripOnTripsTab(ref),
            icon: const Icon(Icons.edit_calendar_outlined, size: 18),
            label: Text(l10n.logTripAction),
          ),
        ],
      ));
    }

    // Chips come from the WHOLE account, so the set on screen doesn't change
    // as you pick through it. A selection that no longer exists (a refetch
    // dropped its trips) falls back to All time rather than filtering to
    // nothing.
    //
    // "There is a chip row" is ONE fact, so it is written once: a filter that
    // outlived its row is a filter with nothing on screen to clear it — a
    // refetch collapsing history onto the selected year would otherwise drop
    // the planned pin and the Planned colophon group with nothing saying why.
    final years = atlasYears(trips, now);
    final showChips = years.length >= 2;
    final year = showChips && years.contains(_year) ? _year : null;
    // One filter, three views. The map and the colophon narrow over ALL trips
    // of that year — planned ones included, still hollow — because the map is
    // *everywhere*; only the index is past-only.
    final filtered = year == null ? trips : tripsInAtlasYear(trips, year);
    // Whether there is a plate at all is answered by the WHOLE account, not by
    // the filter: a year whose trips carry no coordinates (name-only
    // destinations on a logged trip) would otherwise make the map appear and
    // disappear as you pick through the chips. It renders dot-less instead,
    // holding the camera it had.
    final hasPlate = footprintPins(trips, now).isNotEmpty;
    final pins = footprintPins(filtered, now);
    final stats = travelStats(filtered, now);

    _AtlasPaper paper({required bool wide}) => _AtlasPaper(
          // A lone "2026" beside "All time" is chrome that filters nothing —
          // the empty affordance the artifact's thin-history drawing was
          // written to catch. Under two distinct years the row does not
          // render at all.
          years: showChips ? years : const <int>[],
          selectedYear: year,
          onYearSelected: (y) => setState(() => _year = y),
          wrapChips: wide,
          traveled: stats.traveled,
          planned: stats.planned,
          rows: year == null ? rows : atlasRows(trips, now, year: year),
          onOpenTrip: _openTrip,
        );

    return scaffold(LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _wideSeam) {
          // Map-led at width: the plate takes the room and the index reads
          // beside it, rather than a 700px column of paper with a letterboxed
          // map at the top. The two scroll independently — the plate doesn't
          // scroll at all.
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasPlate) ...[
                Expanded(child: _plate(pins)),
                const VerticalDivider(width: 1),
              ],
              SizedBox(
                width: hasPlate ? _sideColumnWidth : constraints.maxWidth,
                child: SingleChildScrollView(
                  child: hasPlate
                      ? paper(wide: true)
                      : PageContainer(child: paper(wide: true)),
                ),
              ),
            ],
          );
        }
        return ListView(
          // No padding: the plate is full-bleed — the atlas does not inherit
          // the trips list's capped reading column, because the surface is
          // map-led. The paper below supplies its own margins.
          padding: EdgeInsets.zero,
          children: [
            if (hasPlate) SizedBox(height: kAtlasPlateHeight, child: _plate(pins)),
            PageContainer(child: paper(wide: false)),
          ],
        );
      },
    ));
  }

  Widget _plate(List<FootprintPin> pins) => Semantics(
        label: context.l10n.tripsListTravelMap,
        child: _AtlasPlate(pins: pins),
      );

  Future<void> _openTrip(BuildContext context, String tripId) async {
    // Guarded here rather than with pushOnce so the resync below is skipped
    // too: a second tap that opened nothing must not refetch the list.
    if (!isTopRoute(context)) return;
    await Navigator.of(context).push(
      locatedRoute(
          TripDetailScreen(tripId: tripId), tripDetailLocation(tripId)),
    );
    // The detail screen can move a trip's dates, which is the one edit that
    // changes what this screen says. Fire-and-forget, like the list's own
    // pop-refresh.
    if (!mounted) return;
    unawaited(ref.read(tripsProvider.notifier).loadTrips());
  }
}

/// Everything on paper: the colophon under the plate, then the index.
///
/// One widget for both layouts so the narrow stack and the wide side column
/// can never drift into two different captions.
class _AtlasPaper extends StatelessWidget {
  /// The years to offer, newest first. Empty means no filter row at all.
  final List<int> years;
  final int? selectedYear;
  final ValueChanged<int?> onYearSelected;

  /// Passed through to [_YearChips]: wrap the chips instead of scrolling them.
  final bool wrapChips;
  final TravelStats traveled;
  final TravelStats planned;
  final List<AtlasRow> rows;
  final Future<void> Function(BuildContext context, String tripId) onOpenTrip;

  const _AtlasPaper({
    required this.years,
    required this.selectedYear,
    required this.onYearSelected,
    required this.wrapChips,
    required this.traveled,
    required this.planned,
    required this.rows,
    required this.onOpenTrip,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // A group whose trip count is zero does not render — the same rule the
    // band uses, and the reason a traveler never meets a row of zeros.
    final groups = [
      if (traveled.trips > 0)
        (
          key: kAtlasTraveledStatsKey,
          label: l10n.tripsListStatsTraveled,
          stats: traveled,
        ),
      if (planned.trips > 0)
        (
          key: kAtlasPlannedStatsKey,
          label: l10n.tripsListStatsPlanned,
          stats: planned,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (years.isNotEmpty) ...[
          _YearChips(
            years: years,
            selected: selectedYear,
            onSelected: onYearSelected,
            wrap: wrapChips,
          ),
          const Divider(height: 1),
        ],
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < groups.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.lg),
                TravelStatGroup(
                  key: groups[i].key,
                  label: groups[i].label,
                  stats: groups[i].stats,
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          child: Column(
            key: kAtlasIndexKey,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(title: l10n.travelAtlasIndexTitle),
              for (var i = 0; i < rows.length; i++) ...[
                // Hairlines between rows, never around them — the index has no
                // box of its own, so a divider only has to separate siblings,
                // and the first row needs none: its heading is directly above.
                if (i > 0) const Divider(height: 1),
                _IndexRow(row: rows[i], onOpen: onOpenTrip),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The explore axis: a filter-chip row that narrows the map, the colophon and
/// the index together. Time is the dimension travel history is actually
/// explored along, and the band this screen came from has no analogue for it.
///
/// Chips, not the vertical rail an earlier draft drew ON the map: those rungs
/// measured ~21px against the 48px [kMinTouchTarget] floor and sat inside a
/// pan-and-zoom gesture arena. `DESIGN.md` blesses this shape outright —
/// *"filter chip rows are the entire secondary navigation on list screens"*.
///
/// **"All time" leads.** It is both the resting state and the only way back.
/// In the scrolling form it is pinned OUTSIDE the scroll view, because
/// [BookingFilterBar] already settled what happens otherwise: on ten years of
/// history the strip scrolls, and an exit that can scroll off-screen is not an
/// exit. There is no leading fade under it — a year half-scrolled beneath
/// reads as a clipped number, not as a stray count attaching itself to the
/// wrong chip, which is the specific harm that mask exists to prevent.
///
/// [wrap] picks the form. A clipped trailing chip is the ordinary
/// horizontal-scroll affordance on a phone and reads as intended; in the
/// ≥900 layout's fixed 400px side column the same clipping reads as a
/// rendering fault, and the column has vertical room a phone does not — so
/// there the chips wrap onto a second line instead.
class _YearChips extends StatelessWidget {
  final List<int> years;
  final int? selected;
  final ValueChanged<int?> onSelected;

  /// True in the wide layout's side column: lay the chips out as a [Wrap]
  /// rather than a pinned chip beside a horizontal scroll view.
  final bool wrap;

  const _YearChips({
    required this.years,
    required this.selected,
    required this.onSelected,
    required this.wrap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final allTime = _chip(
      theme,
      label: l10n.travelAtlasAllTime,
      isSelected: selected == null,
      onTap: () => onSelected(null),
    );
    final yearChips = [
      for (final y in years)
        _chip(
          theme,
          // Formatted, never translated — and never through an ICU int
          // placeholder, which would group 2026 as "2,026".
          label: '$y',
          isSelected: selected == y,
          onTap: () => onSelected(y),
        ),
    ];
    // Bare year numbers say nothing about what tapping one does; the row says
    // it once, for a screen reader, instead of every chip repeating it.
    return Semantics(
      label: l10n.travelAtlasFilterByYear,
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        child: wrap
            ? Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [allTime, ...yearChips],
              )
            : Row(
                children: [
                  allTime,
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      // A traveler with ten years of history overflows any
                      // phone.
                      child: Row(
                        children: [
                          for (var i = 0; i < yearChips.length; i++) ...[
                            if (i > 0) const SizedBox(width: AppSpacing.sm),
                            yearChips[i],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// The house filter chip: fully round, no checkmark, and a padded tap target
  /// so the 48px floor holds even though the chip paints compact.
  ///
  /// **The selected chip stays ENABLED.** Re-tapping it is inert either way,
  /// but `onSelected: null` marks a [ChoiceChip] *disabled*, and M3 then paints
  /// the SELECTED chip in the disabled palette — `onSurface` at 12% under
  /// dimmed ink. Measured in the browser at (217,224,221) against the brand
  /// tint's (224,242,241): it reads as "unavailable", and it leaves the
  /// unselected chips looking louder than the active one. On the row that IS
  /// this surface's navigation, that inverts the hierarchy — and `DESIGN.md`
  /// is explicit that a selected chip takes the brand tint family.
  ///
  /// [AppColors.brandTintFill] rather than the raw tint because that constant
  /// is teal-50: correct on paper, a light block punched into a dark page
  /// anywhere else.
  Widget _chip(
    ThemeData theme, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      // Inert, not disabled: All time is the way back, so a re-tap must not
      // become a second, invisible way to clear.
      onSelected: isSelected ? (_) {} : (_) => onTap(),
      selectedColor: AppColors.brandTintFill(scheme),
      // Stated outright on both sides: an M3 label style left to default
      // paints onSurface, which is the wrong ink on a tinted fill.
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: isSelected
            ? AppColors.onBrandTint(scheme)
            : scheme.onSurfaceVariant,
      ),
      showCheckmark: false,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
  }
}

/// One finished trip, as an index entry: `2026–02 · Lisbon & Porto · 12 days`.
///
/// Typographic rows, deliberately not an icon-card grid — same-size card grids
/// as page structure are a named ban, and Flighty's flag collection translates
/// to type here rather than to tiles.
///
/// The reference column needs no fixed width: every reference is `YYYY–MM`, so
/// with tabular figures they are all exactly as wide as each other and the
/// rail aligns itself at any text scale. A magic column width would align at
/// one scale and clip at the next.
class _IndexRow extends StatelessWidget {
  final AtlasRow row;
  final Future<void> Function(BuildContext context, String tripId) onOpen;

  const _IndexRow({required this.row, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final trip = row.trip;
    final cities = citiesLabel(
      trip.cities,
      two: (a, b) => l10n.citiesTwo(a, b),
      more: (a, b, n) => l10n.citiesMore(a, b, n),
    );
    // The same display-title rule as every other trip surface, so a trip never
    // flips names between the list and its own index entry. citiesLabel's
    // "Tokyo & Kyoto +2 more" cap is what bounds this row's width.
    final name = tripHeadline(trip.title, cities);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return InkWell(
      onTap: () => onOpen(context, trip.id),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTouchTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            children: [
              Text(_reference(row), style: muted),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              // A half-dated trip prints NO length rather than "0 days":
              // dayCount answers 0 whenever either date is missing, and an
              // end-date-only trip can still be past. Same drop the colophon
              // performs on a zero-valued stat.
              if (row.days case final days?) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(l10n.tripDurationDays(days), style: muted),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// `2026–02`, composed here rather than translated: it is digits and an en
  /// dash, with nothing in it to translate and a thousands separator to avoid
  /// (an ICU int placeholder would render the year as "2,026"). The same
  /// reasoning `shortDate` records for its machine-facing form.
  static String _reference(AtlasRow row) =>
      '${row.year}–${row.month.toString().padLeft(2, '0')}';
}

/// The plate: satellite under the footprint pins, and nothing else on it.
///
/// **Interaction follows `_GuideMap`, not the trips-list band.**
/// `InteractiveFlag.all & ~scrollWheelZoom` plus explicit zoom buttons, and
/// both halves are required: the wheel opt-out stops a desktop page-scroll
/// becoming a zoom, and the buttons exist *because* of that opt-out — without
/// them a full-bleed desktop map cannot be zoomed at all.
///
/// The cost this accepts, in the open: on touch, a vertical drag that starts
/// on the plate pans the map instead of scrolling the page. That is the trade
/// `_GuideMap` already ships at 240px mid-page; here the surface is map-led,
/// so it is the right way round.
class _AtlasPlate extends StatefulWidget {
  final List<FootprintPin> pins;

  const _AtlasPlate({required this.pins});

  @override
  State<_AtlasPlate> createState() => _AtlasPlateState();
}

class _AtlasPlateState extends State<_AtlasPlate> {
  /// Marker box: transparent halo padding the 12px dot to the 44px touch
  /// minimum, centered on the coordinate (the trip_map hit-box idiom).
  static const double _pinHitBox = 44;

  /// Zoom for the degenerate single-pin fit, where bounds collapse to a point:
  /// continental context, not a street view — an atlas locates cities on the
  /// globe, it doesn't tour one.
  static const double _singlePinZoom = 4;

  final MapController _controller = MapController();
  double? _lastMapWidth;
  double? _minZoom;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AtlasPlate old) {
    super.didUpdateWidget(old);
    // `initialCameraFit` applies once per FlutterMap state, so a filtered pin
    // set would change the dots and leave the camera over the old extent —
    // the filter would look broken. Re-fit whenever the points move.
    if (!_samePoints(old.pins, widget.pins)) _fitPins();
  }

  static bool _samePoints(List<FootprintPin> a, List<FootprintPin> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].lat != b[i].lat || a[i].lng != b[i].lng) return false;
    }
    return true;
  }

  List<LatLng> get _points => [
        for (final p in widget.pins) LatLng(p.lat, p.lng),
      ];

  /// Move the camera onto the current pins. Deliberately a no-op when there
  /// are none: a year whose trips carry no coordinates keeps the camera it
  /// had, rather than jumping to nowhere.
  void _fitPins() {
    final points = _points;
    if (points.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (points.length == 1) {
          _controller.move(points.first, _singlePinZoom);
        } else {
          _controller.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(AppSpacing.xxl),
          ));
        }
        _clampToFloor();
      } catch (_) {}
    });
  }

  /// Nudge the camera back over the zoom floor. flutter_map adopts a changed
  /// minZoom into the camera's options but never re-clamps the live zoom, so
  /// both a resize and a fresh fit can leave it under the floor — which shows
  /// [appMapBackground] as bars down both sides.
  void _clampToFloor() {
    final floor = _minZoom;
    if (floor == null) return;
    try {
      final camera = _controller.camera;
      _controller.move(camera.center, math.max(camera.zoom, floor));
    } catch (_) {}
  }

  void _zoomBy(double delta) {
    try {
      _controller.move(
          _controller.camera.center, _controller.camera.zoom + delta);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final points = _points;
    const interaction = InteractionOptions(
      flags: InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
    );
    // The zoom floor that keeps the single world filling the box depends on
    // the width the map is given, so the options are assembled in a
    // LayoutBuilder (the TripMap pattern).
    return LayoutBuilder(
      builder: (context, constraints) {
        final minZoom = appMapMinZoomFor(constraints.maxWidth);
        _minZoom = minZoom;

        if (_lastMapWidth != null && _lastMapWidth != constraints.maxWidth) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _clampToFloor();
          });
        }
        _lastMapWidth = constraints.maxWidth;

        final options = points.length == 1
            ? appMapOptions(
                initialCenter: points.first,
                initialZoom: _singlePinZoom,
                minZoom: minZoom,
                interactionOptions: interaction,
              )
            : appMapOptions(
                initialCameraFit: points.isEmpty
                    ? null
                    : AppCameraFitBounds(
                        bounds: LatLngBounds.fromPoints(points),
                        padding: const EdgeInsets.all(AppSpacing.xxl),
                      ),
                minZoom: minZoom,
                interactionOptions: interaction,
              );

        return Stack(
          children: [
            FlutterMap(
              mapController: _controller,
              options: options,
              children: [
                ...appMapTileLayers(context),
                MarkerLayer(
                  markers: [
                    for (final p in widget.pins)
                      Marker(
                        point: LatLng(p.lat, p.lng),
                        width: _pinHitBox,
                        height: _pinHitBox,
                        // Tap-tooltips, as on the band: the two dot styles are
                        // the fast read, the tooltip is the one that can't be
                        // misread — and it is what carries the city names to
                        // a screen reader.
                        child: Tooltip(
                          message: '${p.city} · '
                              '${p.visited ? l10n.tripsListStatsTraveled : l10n.tripsListStatsPlanned}',
                          triggerMode: TooltipTriggerMode.tap,
                          child: FootprintDot(visited: p.visited),
                        ),
                      ),
                  ],
                ),
                // Required by both tile providers' terms, and it keeps its
                // clear space here because nothing else sits on the image.
                appMapAttribution(),
              ],
            ),
            Positioned(
              right: AppSpacing.sm,
              bottom: AppSpacing.sm,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MapControlButton(
                    icon: Icons.add,
                    tooltip: l10n.mapZoomIn,
                    onTap: () => _zoomBy(1),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  MapControlButton(
                    icon: Icons.remove,
                    tooltip: l10n.mapZoomOut,
                    onTap: () => _zoomBy(-1),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
