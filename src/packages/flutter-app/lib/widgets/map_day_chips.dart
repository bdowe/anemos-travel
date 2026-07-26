import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

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
/// dark scrim treatment as the map's segment labels and control buttons.
class MapDayChips extends StatelessWidget {
  /// Vertical band (px) the chip row occupies over the map's top edge when
  /// overlaid at `top: 8`, including breathing room. Callers pass this as
  /// TripMap's `topOverlayInset` so camera fitting keeps markers out from
  /// under the chips.
  static const double mapTopInset = 48;

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

  Widget _chip({
    required String label,
    required int? value,
    bool muted = false,
  }) {
    final isSelected = selected == value;
    // A selected chip keeps the full treatment even when its day is empty —
    // the ring is what says "you are here"; the map's empty state says empty.
    final dim = muted && !isSelected;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(value),
      // Compact: the row floats over the map and must not eat into it.
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      labelPadding: EdgeInsets.zero,
      showCheckmark: false,
      // Dark translucent scrim so the text reads over satellite imagery
      // (same treatment as TripMap's segment labels); selection is a solid
      // white ring + brighter fill rather than a theme tint, which would
      // vanish against imagery. Muted (nothing mapped that day) fades the
      // scrim, border, and label together.
      backgroundColor: Colors.black.withValues(alpha: dim ? 0.35 : 0.6),
      selectedColor: Colors.black.withValues(alpha: 0.8),
      side: BorderSide(
          color: isSelected
              ? Colors.white
              : (dim ? Colors.white12 : Colors.white24)),
      labelStyle: TextStyle(
        color: dim ? Colors.white60 : Colors.white,
        fontSize: 11,
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (dayCount == 0) return const SizedBox.shrink();
    // Same keys the trip-detail filter menu uses, so the chip row and the
    // list agree in every language (specs/i18n-spanish).
    final l10n = context.l10n;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _chip(label: l10n.tripFilterAll, value: null),
          for (var d = 1; d <= dayCount; d++) ...[
            const SizedBox(width: 6),
            _chip(
              label: l10n.tripDayN(d),
              value: d,
              muted: mappedDays != null && !mappedDays!.contains(d),
            ),
          ],
        ],
      ),
    );
  }
}
