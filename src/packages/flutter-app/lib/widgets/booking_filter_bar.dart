import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';

/// One destination the Bookings filter can narrow to, with the count of the
/// bookings it holds. Build these with `bookingDestinationCounts`
/// (trip_detail_derivation.dart), which owns the rule that a chip's count
/// equals what selecting that chip reveals.
typedef BookingDestination = ({
  String value,
  String label,
  int booked,
  int total,
});

/// The Bookings view's filter row: the "Not booked yet" scope chip, an **All**
/// chip, and a horizontally scrolling strip of destination chips carrying
/// their own booked counts (`Prague · 0/3`).
///
/// It replaced a `Wrap` of the same destination chips stacked under a separate
/// scope chip. On an eight-city trip at phone width that wrap cost ~5 rows of
/// chrome before the first booking row — the control took more screen than the
/// content it filtered, and it grew with the trip. One row, at every width.
///
/// Two rules carried over from [MapLegChips], which solved this strip first:
///
///   * The way back is pinned OUTSIDE the scroll view. On a ten-city trip the
///     strip scrolls, and an exit that can scroll off-screen is not an exit.
///   * The selected chip is revealed through the strip's OWN scroll position,
///     never `Scrollable.ensureVisible` — that walks every ancestor scrollable
///     and would yank the trip page's scroll along with it.
///
/// One rule deliberately diverges from it. The map has no "All" chip: there,
/// a chip that is selected at rest would put the strongest treatment on "no
/// filter applied", competing with the ring that means "you are focused on
/// this city". Here the resting state IS the answer to a question the traveler
/// asks ("am I seeing everything?"), and before this chip the only way back to
/// every booking was re-tapping the already-selected chip — an affordance
/// nothing on screen advertised (docs/zen.md: explicit is better than
/// implicit). So All is always painted, and re-tapping a selected destination
/// chip is a no-op rather than a second, invisible way to do the same thing.
///
/// The count rides as a separate [Text] at one weight down rather than being
/// interpolated into the label, so the strip still scans as a row of place
/// names — the same treatment [MapLegChips] gives its qualifier.
class BookingFilterBar extends StatefulWidget {
  /// The "Not booked yet" scope: false = every booking, true = the left-to-book
  /// list. A moved entry point, not a lens of its own — it toggles the same
  /// state the filter menu owned before the view tabs landed.
  final bool unbookedOnly;
  final ValueChanged<bool> onUnbookedOnlyChanged;

  /// Destinations in trip order (a revisited city appears once, its counts
  /// summed), with the 'Other bookings' bucket last when residuals exist.
  /// Fewer than two and the strip renders nothing: there is nothing a
  /// destination filter could narrow.
  final List<BookingDestination> destinations;

  /// The selected destination's value; null = All.
  final String? selected;
  final ValueChanged<String?> onSelected;

  const BookingFilterBar({
    super.key,
    required this.unbookedOnly,
    required this.onUnbookedOnlyChanged,
    required this.destinations,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<BookingFilterBar> createState() => _BookingFilterBarState();
}

class _BookingFilterBarState extends State<BookingFilterBar> {
  final ScrollController _controller = ScrollController();

  /// Rides whichever chip is currently selected so [_revealSelected] can
  /// measure it (SingleChildScrollView lays out off-viewport children, so the
  /// context exists even when the chip is scrolled out of sight).
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // First layout: land the strip on the selected chip. A destination can be
    // selected before this widget ever renders — the selection survives a
    // scope toggle and an offscreen rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  @override
  void didUpdateWidget(covariant BookingFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected && widget.selected != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealSelected(animate: true),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Centers the selected chip in the strip (clamped to its extent), through
  /// this strip's own [ScrollPosition] — see the class doc.
  void _revealSelected({bool animate = false}) {
    if (!mounted || !_controller.hasClients) return;
    final target = _selectedKey.currentContext?.findRenderObject();
    if (target == null) return;
    _controller.position.ensureVisible(
      target,
      alignment: 0.5,
      duration: animate ? const Duration(milliseconds: 200) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  /// One destination chip: the city, its booked count, and the house
  /// selected-chip treatment.
  ///
  /// **The selected chip stays ENABLED.** Re-tapping it is inert either way,
  /// but `onSelected: null` marks a [ChoiceChip] *disabled*, and M3 then
  /// paints the SELECTED chip in the disabled palette — `onSurface` at 12%
  /// under dimmed ink. It reads as "unavailable", and it leaves every
  /// unselected chip in the strip looking louder than the active one, which
  /// inverts the hierarchy on a row that IS this view's navigation.
  /// `DESIGN.md` is explicit that a selected chip takes the brand tint
  /// family. The atlas's year chips carry the same fix, for the same reason.
  ///
  /// [AppColors.brandTintFill] rather than the raw tint because that constant
  /// is teal-50: correct on paper, a light block punched into a dark page
  /// anywhere else. The label style is stated outright on both sides — an M3
  /// label left to default paints `onSurface`, the wrong ink on a tinted
  /// fill — and the count beside it takes the same ink, being the same word.
  Widget _destinationChip(ThemeData theme, BookingDestination d) {
    final scheme = theme.colorScheme;
    final isSelected = widget.selected == d.value;
    final chip = ChoiceChip(
      // Label and count are two Texts, never one interpolated string: the
      // count is a qualifier, not part of the city's name (and every finder
      // that looks for the bare label keeps working).
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(d.label),
          Text(
            ' · ${d.booked}/${d.total}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isSelected
                  ? AppColors.onBrandTint(scheme)
                  : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      selected: isSelected,
      // A re-tap is a dead gesture, not a clear: All is the way back. Inert,
      // not disabled — see this method's doc.
      onSelected: isSelected ? (_) {} : (_) => widget.onSelected(d.value),
      selectedColor: AppColors.brandTintFill(scheme),
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color:
            isSelected ? AppColors.onBrandTint(scheme) : scheme.onSurfaceVariant,
      ),
      showCheckmark: false,
      // Full 48px hit box even though the chip paints compact — the padded
      // tap target's extra area is transparent, and compact density would
      // shave it under the 44px touch minimum.
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
    return isSelected ? KeyedSubtree(key: _selectedKey, child: chip) : chip;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // One destination is not a filter — it would show exactly what All shows.
    final showStrip = widget.destinations.length > 1;
    final pinned = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilterChip(
          label: Text(l10n.tripFilterUnbooked),
          selected: widget.unbookedOnly,
          onSelected: widget.onUnbookedOnlyChanged,
          materialTapTargetSize: MaterialTapTargetSize.padded,
        ),
        if (showStrip) ...[
          const SizedBox(width: AppSpacing.sm),
          ChoiceChip(
            label: Text(l10n.tripBookingsAllDestinations),
            selected: widget.selected == null,
            // Inert, not disabled — see [_destinationChip]. All is this
            // strip's resting state, so it is the chip most often selected
            // and the one the dimming showed on most.
            onSelected: widget.selected == null
                ? (_) {}
                : (_) => widget.onSelected(null),
            selectedColor: AppColors.brandTintFill(scheme),
            labelStyle: theme.textTheme.labelLarge?.copyWith(
              color: widget.selected == null
                  ? AppColors.onBrandTint(scheme)
                  : scheme.onSurfaceVariant,
            ),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ],
      ],
    );
    if (!showStrip) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Align(alignment: Alignment.centerLeft, child: pinned),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      // The two pinned controls are capped at half the row and scale down
      // inside it, rather than taking their natural width. Natural width is
      // what a 320px Spanish row at 1.3× text overflowed by 94px, and short of
      // overflowing it starved the strip: on a 420px body the pinned pair left
      // ~180px, less than one "Gothenburg · 0/2" chip, so the strip could
      // never show a whole destination. The cap is on the half that can be
      // read at a glance; the strip is the half that has somewhere to put the
      // overflow. FittedBox scale-down engages only when the pair genuinely
      // cannot fit (tiny windows, large accessibility text) — the same lever,
      // for the same reason, as the header's view tabs.
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: pinned,
              ),
            ),
            Expanded(
              // The leading edge fades out ONCE the strip has scrolled. A chip
              // scrolled under the pinned pair shows only its TAIL, and a
              // chip's tail is its count — so a hard edge parks a stray
              // "· 0/2" beside the All chip, where it reads as All's own
              // count. All deliberately carries no count (that number is the
              // tab pill's), and the one thing this edge must never do is
              // appear to give it one.
              //
              // At rest there is nothing sliding under, so the fade would only
              // dim the first destination for no reason — hence the listen on
              // the offset rather than a constant gradient.
              //
              // The mask stays in the tree at every offset and only its
              // GRADIENT changes. Swapping the ShaderMask in and out instead
              // re-parents the scroll view, which rebuilds it and drops the
              // ScrollController's position — the strip snapped back to the
              // first chip the moment the fade engaged.
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final fadeEnd =
                      _controller.hasClients && _controller.offset > 1
                          ? 0.10
                          : 0.0;
                  return ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: const [Colors.transparent, Colors.black],
                      stops: [0.0, fadeEnd],
                    ).createShader(rect),
                    child: child,
                  );
                },
                child: SingleChildScrollView(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  // Draggable even when the chips fit; the leading pad keeps
                  // the first chip off the All chip it scrolls under.
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  child: Row(
                    children: [
                      for (final (i, d) in widget.destinations.indexed) ...[
                        if (i > 0) const SizedBox(width: AppSpacing.xs),
                        _destinationChip(theme, d),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
