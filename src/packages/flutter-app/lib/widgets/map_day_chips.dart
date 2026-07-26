import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';

/// Day-filter chips overlaid on a trip map: `All · Day 1 · … · Day N`
/// (specs/today-mode). [selected] is the 1-based day, null meaning All;
/// tapping a chip reports the new value through [onSelected] (tapping the
/// already-selected chip re-reports it — harmless for a filter).
///
/// Renders nothing when [dayCount] is 0 (undated trip with no day-tagged
/// items). Untagged items are an All-only affair, so there is deliberately
/// no "Unscheduled" chip.
///
/// The chips sit over satellite imagery, so they use the same translucent
/// dark scrim treatment ([AppColors.mapScrim]) as the map's segment labels
/// and control buttons. The strip keeps the selected chip in view: the
/// full-screen map can open with a late day preselected (inherited from the
/// inline card), which would otherwise rest off-screen with no cue that the
/// row scrolls.
class MapDayChips extends StatefulWidget {
  /// Vertical band (px) the chip row occupies over the map's top edge when
  /// overlaid at `top: 8`, including breathing room: 8 offset + the 48px
  /// chip hit box (padded tap target) + 8 clearance. Callers pass this as
  /// TripMap's `topOverlayInset` so camera fitting keeps markers out from
  /// under the chips.
  static const double mapTopInset = 64;

  final int dayCount;
  final int? selected;
  final ValueChanged<int?> onSelected;

  /// Days that have something plottable (a coordinate-bearing item tagged to
  /// the day, or a stay covering its night — see `daysWithMappedContent`).
  /// Chips for other days stay tappable but render muted, signalling "nothing
  /// on the map here" before the tap. Null (the default) mutes nothing.
  final Set<int>? mappedDays;

  const MapDayChips({
    super.key,
    required this.dayCount,
    required this.selected,
    required this.onSelected,
    this.mappedDays,
  });

  @override
  State<MapDayChips> createState() => _MapDayChipsState();
}

class _MapDayChipsState extends State<MapDayChips> {
  final ScrollController _controller = ScrollController();

  /// Rides whichever chip is currently selected so [_revealSelected] can
  /// measure it (SingleChildScrollView lays out off-viewport children, so the
  /// context exists even when the chip is scrolled out of sight).
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // First layout: land the strip on the selected chip.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  @override
  void didUpdateWidget(covariant MapDayChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
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

  /// Centers the selected chip in the strip (clamped to its extent). Goes
  /// through this strip's own [ScrollPosition] — never `Scrollable.ensureVisible`,
  /// which walks every ancestor scrollable and would also yank the page
  /// scroll hosting the inline map card on trip detail.
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

  Widget _chip({
    required String label,
    required int? value,
    bool muted = false,
  }) {
    final isSelected = widget.selected == value;
    // A selected chip keeps the full treatment even when its day is empty —
    // the ring is what says "you are here"; the map's empty state says empty.
    final dim = muted && !isSelected;
    final chip = ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => widget.onSelected(value),
      // Compact visual (tight padding, small label) so the row doesn't eat
      // into the map, but a full 48px hit box: the padded tap target's extra
      // area is transparent, and density must stay standard — compact would
      // shave the hit box to 40px, under the 44px touch minimum.
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      labelPadding: EdgeInsets.zero,
      showCheckmark: false,
      // Dark translucent scrim so the text reads over satellite imagery
      // (AppColors.mapScrim — shared with TripMap's segment labels and the
      // map control buttons); selection is a solid white ring + brighter
      // fill rather than a theme tint, which would vanish against imagery.
      // Muted (nothing mapped that day) fades the scrim, border, and label
      // together.
      backgroundColor:
          dim ? Colors.black.withValues(alpha: 0.35) : AppColors.mapScrim,
      selectedColor: Colors.black.withValues(alpha: 0.8),
      side: BorderSide(
        color:
            isSelected ? Colors.white : (dim ? Colors.white12 : Colors.white24),
      ),
      labelStyle: TextStyle(
        color: dim ? Colors.white60 : Colors.white,
        fontSize: 11,
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
      ),
    );
    return isSelected ? KeyedSubtree(key: _selectedKey, child: chip) : chip;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dayCount == 0) return const SizedBox.shrink();
    // Same keys the trip-detail filter menu uses, so the chip row and the
    // list agree in every language (specs/i18n-spanish).
    final l10n = context.l10n;
    return SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      // Draggable even when the chips fit, and end padding so the first/last
      // chip never sits flush against the map edge.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        children: [
          _chip(label: l10n.tripFilterAll, value: null),
          for (var d = 1; d <= widget.dayCount; d++) ...[
            const SizedBox(width: 6),
            _chip(
              label: l10n.tripDayN(d),
              value: d,
              muted:
                  widget.mappedDays != null && !widget.mappedDays!.contains(d),
            ),
          ],
        ],
      ),
    );
  }
}
