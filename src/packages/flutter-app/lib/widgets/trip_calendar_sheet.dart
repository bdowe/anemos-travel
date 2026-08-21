import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/date_formats.dart';
import '../utils/leg_ranges.dart';
import 'section_header.dart';
import 'status_pill.dart';

/// Height of the leg ribbon inside a [kMinTouchTarget] day cell — the band
/// sits under the day number with the cell's touch slack left around it.
const double _kBandHeight = 30;

/// Half the gutter that separates the two halves of a travel day, so the
/// check-out and check-in ribbons read as two ends meeting rather than one
/// band changing color. One [AppSpacing.sm] step of gap, split evenly, which
/// is what keeps the ribbon's length honest: the gutter is centred on the
/// cell's midpoint, so it costs each side the same.
///
/// It is a whole step rather than a hairline because the day number is
/// centred too, and the seam runs straight through it. At half this width
/// the two caps closed around the digit and the day read as belonging to
/// whichever tone happened to be on its right; at this width the number sits
/// in clean space with one city to its left and the next to its right.
const double _kSeam = AppSpacing.sm / 2;

/// One city leg as the trip calendar renders it. Built by the caller from the
/// trip-detail derivation's [TripDerivation.visibleRanges] (index-aligned
/// with its legs) — the sheet consumes the one derivation, it does not derive
/// legs itself.
///
/// [start] is the day the traveler CHECKS IN and [end] the day they CHECK
/// OUT, so `end - start` is the leg's night count and consecutive legs share
/// a boundary date by construction (you check out of one city and into the
/// next on the same day). The grid renders that literally — see
/// [_DayRibbon].
typedef TripCalendarLeg = ({
  String key,
  String label,
  DateTime start,
  DateTime end,
});

/// How one calendar day carries the legs that touch it.
///
/// A leg's ribbon runs from the MIDDLE of its check-in cell to the MIDDLE of
/// its check-out cell, so the ribbon's length in cell-widths is exactly its
/// night count and a travel day shows two tones meeting mid-cell. That is the
/// booking-calendar grammar (Airbnb, Booking, Google Hotels all draw a stay
/// this way) and it is why the shape is not "one cell, one owner".
///
/// It used to be: each date went to the FIRST leg that claimed it, so the
/// shared boundary day fell to the city being left. That painted the day you
/// leave as a full day in the old city and dropped the night you arrive in
/// the new one, which put every leg after the first one day late and gave the
/// first leg `nights + 1` cells. A 2-night Amsterdam drew three full cells,
/// and the band and the "2 nights" label underneath it disagreed on screen.
typedef _DayRibbon = ({
  /// A leg strictly inside its own span here — the cell is one solid band.
  int? spanning,

  /// The leg CHECKING OUT here: it owns the cell's left half.
  int? checkOut,

  /// The leg CHECKING IN here: it owns the cell's right half.
  int? checkIn,

  /// Legs whose check-in and check-out are both this date — a zero-night
  /// stop, the interim state a `set_leg_dates` squeeze leaves behind. Drawn
  /// as a centred pip so a squeezed city is visible rather than absent.
  List<int> stops,
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

  /// Every date the trip spans, mapped to the ribbon it carries. One pass
  /// over the legs; a date absent from the map lies outside every leg.
  ///
  /// Nothing arbitrates here — each leg draws its own true span, and legs
  /// interlock because a shared boundary date is one leg's check-out (left
  /// half) and the next leg's check-in (right half).
  Map<DateTime, _DayRibbon> _ribbons() {
    final out = <DateTime, _DayRibbon>{};
    _DayRibbon at(DateTime d) =>
        out[d] ??
        (spanning: null, checkOut: null, checkIn: null, stops: const <int>[]);

    for (var i = 0; i < widget.legs.length; i++) {
      final leg = widget.legs[i];
      final rawStart = _dateOf(leg.start);
      final rawEnd = _dateOf(leg.end);
      // A leg wholly outside the trip's own span is dropped rather than
      // clamped: clamping both ends would collapse it onto the trip's first
      // or last day and invent a stop that isn't there.
      if (rawEnd.isBefore(_start) || rawStart.isAfter(_end)) continue;
      final legStart = _clampToTrip(rawStart);
      final legEnd = _clampToTrip(rawEnd);
      if (legEnd.isBefore(legStart)) continue;
      if (legStart == legEnd) {
        final r = at(legStart);
        out[legStart] = (
          spanning: r.spanning,
          checkOut: r.checkOut,
          checkIn: r.checkIn,
          stops: [...r.stops, i],
        );
        continue;
      }
      // Check-in day: the right half — FIRST claim wins, so on a shared
      // boundary the right half is the next city you go to. Check-out takes
      // the LAST claim for the mirror reason: it is the city you were just
      // in. Legs arrive in itinerary order, so the pair resolves a boundary
      // date to "leg i out, leg i+1 in" without any tie-breaking rule.
      final ci = at(legStart);
      out[legStart] = (
        spanning: ci.spanning,
        checkOut: ci.checkOut,
        checkIn: ci.checkIn ?? i,
        stops: ci.stops,
      );
      // Check-out day: the left half.
      final co = at(legEnd);
      out[legEnd] = (
        spanning: co.spanning,
        checkOut: i,
        checkIn: co.checkIn,
        stops: co.stops,
      );
      // Every night strictly between is a solid cell.
      for (var d = DateTime(legStart.year, legStart.month, legStart.day + 1);
          d.isBefore(legEnd);
          d = DateTime(d.year, d.month, d.day + 1)) {
        final r = at(d);
        out[d] = (
          spanning: r.spanning ?? i,
          checkOut: r.checkOut,
          checkIn: r.checkIn,
          stops: r.stops,
        );
      }
    }
    return out;
  }

  static DateTime _dateOf(DateTime d) => DateTime(d.year, d.month, d.day);

  /// [d] held inside the trip's own span — a leg overhanging either end
  /// renders up to the edge. Callers drop a leg that lies wholly outside
  /// before clamping, so this never collapses a real span to a point.
  DateTime _clampToTrip(DateTime d) {
    if (d.isBefore(_start)) return _start;
    if (d.isAfter(_end)) return _end;
    return d;
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
    final ribbons = _ribbons();
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
        for (final month in _months()) _monthGrid(context, month, ribbons),
        // A one-city trip has no travel day to explain, so the key would be
        // describing a mark the grid never draws.
        if (widget.legs.length > 1) ...[
          const SizedBox(height: AppSpacing.md),
          _travelDayKey(context),
        ],
        if (_selectedLeg != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _detailRow(context, widget.legs[_selectedLeg!], _selectedLeg!),
        ],
      ],
    );
  }

  /// The one line that teaches the grid's only non-obvious mark: a day
  /// carrying two tones is a day the traveler moves. It sits under the
  /// months rather than above them — you meet the two-tone cell first and
  /// the key answers the question it raises, instead of explaining a grammar
  /// nobody has seen yet.
  ///
  /// The glyph is the real thing at cell scale, not an icon standing in for
  /// it: the same two half-ribbons in the same two tones the grid draws.
  Widget _travelDayKey(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      key: const ValueKey('trip-calendar-key'),
      children: [
        SizedBox(
          width: AppSpacing.xxl,
          height: _kBandHeight,
          child: Row(
            children: [
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(right: _kSeam),
                  decoration: BoxDecoration(
                    color: AppColors.legBand(0),
                    borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(AppRadius.sm)),
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(left: _kSeam),
                  decoration: BoxDecoration(
                    color: AppColors.legBand(1),
                    borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(AppRadius.sm)),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            context.l10n.tripCalendarTravelDayKey,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
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
    Map<DateTime, _DayRibbon> ribbons,
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
                      ribbons: ribbons,
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
    required Map<DateTime, _DayRibbon> ribbons,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final wash = weekendColumn ? AppColors.weekendWash(scheme) : null;
    final dayNumber = cellIndex - offset + 1;
    if (dayNumber < 1 || dayNumber > daysInMonth) {
      // Adjacent-month filler: blank, but still washed so a weekend column
      // reads as one continuous stripe.
      return Container(height: kMinTouchTarget, color: wash);
    }
    final date = DateTime(month.year, month.month, dayNumber);
    final inTrip = !date.isBefore(_start) && !date.isAfter(_end);
    final ribbon = ribbons[date];
    final now = widget.today ?? DateTime.now();
    final isToday = inTrip &&
        date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;

    final numberStyle = theme.textTheme.bodyMedium?.copyWith(
      color: inTrip ? scheme.onSurface : theme.disabledColor,
      fontWeight: inTrip ? FontWeight.w600 : FontWeight.w400,
    );

    return Semantics(
      // Screen readers get the fact the two tones carry visually: a travel
      // day names both cities and which way round they go. The grid's own
      // day numbers stay the label for every ordinary day.
      label: _daySemantics(l10n, date, ribbon),
      child: InkWell(
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
              if (ribbon != null)
                Positioned(
                  left: 0,
                  right: 0,
                  height: _kBandHeight,
                  child: _ribbonBand(date, ribbon),
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
      ),
    );
  }

  /// One day's ribbon. A solid cell when the traveler simply wakes and sleeps
  /// in the same city; two halves meeting mid-cell when they move.
  ///
  /// Caps round only where a stay actually begins or ends, so cells inside a
  /// stay — across a row and across a month wrap — still read as one band.
  Widget _ribbonBand(DateTime date, _DayRibbon ribbon) {
    final selected = _selectedLeg;
    bool dim(int i) => selected != null && selected != i;

    if (ribbon.spanning != null && ribbon.stops.isEmpty) {
      return Container(
        key: ValueKey('trip-calendar-band-${_iso(date)}'),
        color: AppColors.legBand(ribbon.spanning!, muted: dim(ribbon.spanning!)),
      );
    }

    // A zero-night stop has no half of its own to sit in — it is drawn as a
    // centred pip over whatever else claims the day, so a city squeezed to
    // nothing is visibly still on the itinerary instead of silently gone.
    final pip = ribbon.stops.isEmpty ? null : ribbon.stops.first;

    return Stack(
      key: ValueKey('trip-calendar-band-${_iso(date)}'),
      children: [
        Row(
          children: [
            Expanded(
              child: ribbon.checkOut == null
                  ? const SizedBox.shrink()
                  : Container(
                      key: ValueKey('trip-calendar-checkout-${_iso(date)}'),
                      margin: const EdgeInsets.only(right: _kSeam),
                      decoration: BoxDecoration(
                        color: AppColors.legBand(ribbon.checkOut!,
                            muted: dim(ribbon.checkOut!)),
                        borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(AppRadius.sm)),
                      ),
                    ),
            ),
            Expanded(
              child: ribbon.checkIn == null
                  ? const SizedBox.shrink()
                  : Container(
                      key: ValueKey('trip-calendar-checkin-${_iso(date)}'),
                      margin: const EdgeInsets.only(left: _kSeam),
                      decoration: BoxDecoration(
                        color: AppColors.legBand(ribbon.checkIn!,
                            muted: dim(ribbon.checkIn!)),
                        borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(AppRadius.sm)),
                      ),
                    ),
            ),
          ],
        ),
        if (pip != null)
          Center(
            child: Container(
              key: ValueKey('trip-calendar-stop-${_iso(date)}'),
              width: AppSpacing.md,
              height: AppSpacing.md,
              decoration: BoxDecoration(
                color: AppColors.legTone(pip),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }

  /// The accessible name for a day cell: the two-tone travel day spelled out,
  /// and nothing added anywhere else — an ordinary day inside a stay is
  /// already announced by its number and its row.
  String? _daySemantics(
      AppLocalizations l10n, DateTime date, _DayRibbon? ribbon) {
    if (ribbon == null) return null;
    final out = ribbon.checkOut;
    final into = ribbon.checkIn;
    if (out == null && into == null) return null;
    final day = mmmed().format(date);
    if (out != null && into != null) {
      return l10n.tripCalendarTravelDaySemantics(
          day, widget.legs[out].label, widget.legs[into].label);
    }
    if (into != null) {
      return l10n.tripCalendarCheckInSemantics(day, widget.legs[into].label);
    }
    return l10n.tripCalendarCheckOutSemantics(day, widget.legs[out!].label);
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
            // Naming the two ends beats printing the span: "Aug 24 – Aug 26"
            // reads as three days in the city to anyone who hasn't decided
            // whether the second date is a night or a departure, and then
            // argues with the nights beside it. A zero-night stop has no
            // ends to name, so it keeps the plain date.
            nights > 0
                ? '${l10n.tripCalendarCheckInOut(mmmed().format(leg.start), mmmed().format(leg.end))}'
                    ' ${l10n.tripLegNights(nights)}'
                : formatWeekdayRange(leg.start, leg.end),
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
