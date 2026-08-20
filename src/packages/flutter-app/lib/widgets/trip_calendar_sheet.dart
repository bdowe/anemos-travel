import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/date_formats.dart';
import '../utils/leg_ranges.dart';
import 'section_header.dart';
import 'status_pill.dart';

/// One city leg as the trip calendar renders it. Built by the caller from the
/// trip-detail derivation's [TripDerivation.visibleRanges] (index-aligned
/// with its legs) — the sheet consumes the one derivation, it does not derive
/// legs itself.
typedef TripCalendarLeg = ({
  String key,
  String label,
  DateTime start,
  DateTime end,
});

/// Opens the trip calendar: a compact whole-trip month grid whose day cells
/// carry each city leg as a continuous color band, so the traveler can see
/// which days are weekends before asking to swap or shift a city.
///
/// [onJumpToDay] gets the 1-based trip day of a tapped cell — the sheet
/// closes itself first, and the caller jump-scrolls the itinerary (the Today
/// chip's `_scrollToDay`). [onAskToChange] gets the leg selected in the
/// legend; null hides the button (viewers, offline) — the caller hands the
/// leg to the trip's refine chat. Both callbacks run AFTER the sheet pops
/// (the city-events sheet's pattern), so nothing strands behind the barrier.
///
/// No Scaffold inside the sheet, so the framework's Escape→dismiss handling
/// works as-is (a nested Scaffold would swallow DismissIntent — the
/// trip_map_screen trap).
Future<void> showTripCalendarSheet(
  BuildContext context, {
  required DateTime tripStart,
  required DateTime tripEnd,
  required List<TripCalendarLeg> legs,
  required ValueChanged<int> onJumpToDay,
  required ValueChanged<TripCalendarLeg>? onAskToChange,
  DateTime? today,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Width cap centers the sheet on desktop, same as the wear/health/events
    // sheets: a seven-column grid reads stranded at full bleed.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      void closeThen(VoidCallback action) {
        final route = ModalRoute.of(sheetContext);
        if (route?.isCurrent ?? false) Navigator.of(sheetContext).pop();
        action();
      }

      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
            child: TripCalendarSheetBody(
              tripStart: tripStart,
              tripEnd: tripEnd,
              legs: legs,
              today: today,
              onJumpToDay: (day) => closeThen(() => onJumpToDay(day)),
              onAskToChange: onAskToChange == null
                  ? null
                  : (leg) => closeThen(() => onAskToChange(leg)),
            ),
          ),
        ),
      );
    },
  );
}

/// The sheet body: header + summary, the per-leg legend, one month grid per
/// month the trip spans, and — once a legend chip is tapped — the leg's
/// detail row. Provider-free like the sibling sheet bodies, so it unit-tests
/// without a harness. Public so tests can scope finders to the sheet.
class TripCalendarSheetBody extends StatefulWidget {
  final DateTime tripStart;
  final DateTime tripEnd;
  final List<TripCalendarLeg> legs;

  /// Tapped day cell, as a 1-based trip day. The MODAL wrapper owns closing
  /// the sheet; the body only reports.
  final ValueChanged<int> onJumpToDay;

  /// "Ask to change" for the selected leg; null hides the button.
  final ValueChanged<TripCalendarLeg>? onAskToChange;

  /// The device-local "today", injectable for tests. The filled-circle marker
  /// renders only when it falls inside the trip.
  final DateTime? today;

  const TripCalendarSheetBody({
    super.key,
    required this.tripStart,
    required this.tripEnd,
    required this.legs,
    required this.onJumpToDay,
    this.onAskToChange,
    this.today,
  });

  @override
  State<TripCalendarSheetBody> createState() => _TripCalendarSheetBodyState();
}

class _TripCalendarSheetBodyState extends State<TripCalendarSheetBody> {
  /// The legend-selected leg whose detail row is showing, or null.
  int? _selectedLeg;

  DateTime get _start => DateTime(
      widget.tripStart.year, widget.tripStart.month, widget.tripStart.day);

  DateTime get _end =>
      DateTime(widget.tripEnd.year, widget.tripEnd.month, widget.tripEnd.day);

  /// Day-of-travel ownership: each calendar date inside the trip belongs to
  /// exactly ONE leg's band. Legs share their boundary day by construction
  /// (a leg renders from the previous leg's visible end), and that day
  /// belongs to the city being left — the same rule [CityGroup.emptyDays]
  /// documents — so the FIRST leg to claim a date keeps it. [ownedStart] /
  /// [ownedEnd] are each leg's first/last OWNED date (null when it owns
  /// none — a zero-night squeezed leg), which is where the band's rounded
  /// caps go.
  ({
    Map<DateTime, int> owners,
    List<DateTime?> ownedStart,
    List<DateTime?> ownedEnd,
  }) _ownership() {
    final owners = <DateTime, int>{};
    final ownedStart = List<DateTime?>.filled(widget.legs.length, null);
    final ownedEnd = List<DateTime?>.filled(widget.legs.length, null);
    for (var i = 0; i < widget.legs.length; i++) {
      final leg = widget.legs[i];
      var d = DateTime(leg.start.year, leg.start.month, leg.start.day);
      final legEnd = DateTime(leg.end.year, leg.end.month, leg.end.day);
      if (d.isBefore(_start)) d = _start;
      for (; !d.isAfter(legEnd) && !d.isAfter(_end);
          d = DateTime(d.year, d.month, d.day + 1)) {
        if (owners.containsKey(d)) continue;
        owners[d] = i;
        ownedStart[i] ??= d;
        ownedEnd[i] = d;
      }
    }
    return (owners: owners, ownedStart: ownedStart, ownedEnd: ownedEnd);
  }

  /// Saturday/Sunday days inside [start]..[end], inclusive — the detail
  /// row's weekend pill.
  static int _weekendDayCount(DateTime start, DateTime end) {
    var count = 0;
    for (var d = DateTime(start.year, start.month, start.day);
        !d.isAfter(end);
        d = DateTime(d.year, d.month, d.day + 1)) {
      if (d.weekday >= DateTime.saturday) count++;
    }
    return count;
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final ownership = _ownership();
    final days = _end.difference(_start).inDays + 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionHeader(title: l10n.tripCalendarTitle),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${formatShortRange(_start, _end)} · '
          '${l10n.tripDurationDays(days)} · '
          '${l10n.tripCitiesCount(widget.legs.length)}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (var i = 0; i < widget.legs.length; i++)
              FilterChip(
                key: ValueKey('trip-calendar-legend-$i'),
                showCheckmark: false,
                avatar: Container(
                  width: AppSpacing.md,
                  height: AppSpacing.md,
                  decoration: BoxDecoration(
                    color: AppColors.legTone(i),
                    shape: BoxShape.circle,
                  ),
                ),
                label: Text(widget.legs[i].label),
                selected: _selectedLeg == i,
                // Selected takes the brand tint family (the chip rule).
                selectedColor: AppColors.brandTintFill(scheme),
                visualDensity: VisualDensity.compact,
                onSelected: (sel) =>
                    setState(() => _selectedLeg = sel ? i : null),
              ),
          ],
        ),
        for (final month in _months()) _monthGrid(context, month, ownership),
        if (_selectedLeg != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _detailRow(context, widget.legs[_selectedLeg!], _selectedLeg!),
        ],
      ],
    );
  }

  /// The months the trip spans, first-of-month each, ascending.
  List<DateTime> _months() {
    final months = <DateTime>[];
    var m = DateTime(_start.year, _start.month);
    final last = DateTime(_end.year, _end.month);
    while (!m.isAfter(last)) {
      months.add(m);
      m = DateTime(m.year, m.month + 1);
    }
    return months;
  }

  Widget _monthGrid(
    BuildContext context,
    DateTime month,
    ({
      Map<DateTime, int> owners,
      List<DateTime?> ownedStart,
      List<DateTime?> ownedEnd,
    }) ownership,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final first = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Monday-first leading blanks: DateTime.weekday is Mon=1..Sun=7.
    final offset = first.weekday - DateTime.monday;
    final rows = ((offset + daysInMonth) / 7).ceil();
    final headers = weekdayHeaders();

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            ymmmm().format(month),
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (var c = 0; c < 7; c++)
                Expanded(
                  child: Container(
                    height: AppSpacing.xl,
                    // The weekend tint on the header cell is the same wash
                    // the column below carries, so SAT/SUN read as marked
                    // from the label down.
                    color: c >= DateTime.saturday - 1
                        ? AppColors.weekendWash(scheme)
                        : null,
                    alignment: Alignment.center,
                    child: Text(
                      headers[c],
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
            ],
          ),
          for (var r = 0; r < rows; r++)
            Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(
                    child: _dayCell(
                      context,
                      month: month,
                      cellIndex: r * 7 + c,
                      offset: offset,
                      daysInMonth: daysInMonth,
                      weekendColumn: c >= DateTime.saturday - 1,
                      ownership: ownership,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _dayCell(
    BuildContext context, {
    required DateTime month,
    required int cellIndex,
    required int offset,
    required int daysInMonth,
    required bool weekendColumn,
    required ({
      Map<DateTime, int> owners,
      List<DateTime?> ownedStart,
      List<DateTime?> ownedEnd,
    }) ownership,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wash = weekendColumn ? AppColors.weekendWash(scheme) : null;
    final dayNumber = cellIndex - offset + 1;
    if (dayNumber < 1 || dayNumber > daysInMonth) {
      // Adjacent-month filler: blank, but still washed so a weekend column
      // reads as one continuous stripe.
      return Container(height: kMinTouchTarget, color: wash);
    }
    final date = DateTime(month.year, month.month, dayNumber);
    final inTrip = !date.isBefore(_start) && !date.isAfter(_end);
    final legIndex = ownership.owners[date];
    final now = widget.today ?? DateTime.now();
    final isToday = inTrip &&
        date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;

    // The band's rounded caps sit on the leg's first/last OWNED day (a
    // boundary day belongs to the city being left); square elsewhere, so
    // same-leg cells — across a row and across a month wrap — read as one
    // continuous band.
    BorderRadius? bandRadius;
    if (legIndex != null) {
      bandRadius = BorderRadius.horizontal(
        left: date == ownership.ownedStart[legIndex]
            ? const Radius.circular(AppRadius.sm)
            : Radius.zero,
        right: date == ownership.ownedEnd[legIndex]
            ? const Radius.circular(AppRadius.sm)
            : Radius.zero,
      );
    }

    final numberStyle = theme.textTheme.bodyMedium?.copyWith(
      color: inTrip ? scheme.onSurface : theme.disabledColor,
      fontWeight: inTrip ? FontWeight.w600 : FontWeight.w400,
    );

    return InkWell(
      key: ValueKey('trip-calendar-day-${_iso(date)}'),
      onTap: inTrip
          // inTrip guarantees date >= _start, so this is the 1-based
          // trip day the jump-scroll resolves.
          ? () => widget.onJumpToDay(date.difference(_start).inDays + 1)
          : null,
      child: Container(
        key: wash == null
            ? null
            // Test/diagnostic marker for the weekend wash: the column's
            // stripe is otherwise just a color on a Container.
            : ValueKey('trip-calendar-weekend-${_iso(date)}'),
        height: kMinTouchTarget,
        color: wash,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (legIndex != null)
              Positioned(
                left: 0,
                right: 0,
                height: 30,
                child: Container(
                  key: ValueKey('trip-calendar-band-${_iso(date)}'),
                  decoration: BoxDecoration(
                    color: AppColors.legBand(legIndex),
                    borderRadius: bandRadius,
                  ),
                ),
              ),
            if (isToday)
              Container(
                key: const ValueKey('trip-calendar-today'),
                width: AppSpacing.xxl,
                height: AppSpacing.xxl,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$dayNumber',
                  style: numberStyle?.copyWith(color: scheme.onPrimary),
                ),
              )
            else
              Text('$dayNumber', style: numberStyle),
          ],
        ),
      ),
    );
  }

  /// The selected leg's detail row: label, range with weekdays, nights, the
  /// weekend-count pill, and the refine-chat handoff.
  Widget _detailRow(BuildContext context, TripCalendarLeg leg, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final nights = nightsBetween(leg.start, leg.end);
    final weekends = _weekendDayCount(leg.start, leg.end);

    return Container(
      key: const ValueKey('trip-calendar-detail'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: AppRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: AppSpacing.md,
                height: AppSpacing.md,
                decoration: BoxDecoration(
                  color: AppColors.legTone(index),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  leg.label,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (weekends > 0)
                StatusPill.custom(
                  label: l10n.tripCalendarWeekendDays(weekends),
                  background: scheme.surfaceContainerHighest,
                  foreground: scheme.onSurfaceVariant,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${formatWeekdayRange(leg.start, leg.end)}'
            '${nights > 0 ? ' ${l10n.tripLegNights(nights)}' : ''}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (widget.onAskToChange != null) ...[
            const SizedBox(height: AppSpacing.md),
            FilledButton.tonalIcon(
              onPressed: () => widget.onAskToChange!(leg),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(l10n.tripCalendarAskToChange),
            ),
          ],
        ],
      ),
    );
  }
}
