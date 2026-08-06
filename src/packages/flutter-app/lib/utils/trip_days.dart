// Shared trip-day math (specs/today-mode) so the trip detail screen, the
// shared trip view, and the add-to-trip sheet all agree on what "Day N" means.
//
// Pure and string-based like trip_format.dart: callers pass the raw ISO
// date-only strings (YYYY-MM-DD) straight off the models — no model imports.
// Dart parses date-only strings as **local** midnight, so all day math here is
// in the device's local calendar; "today" is wherever the device is.

/// The 1-based trip day that [when]'s **device-local calendar date** falls on,
/// or null when [startDate] is missing/unparseable or the date lands outside
/// the trip (before day 1, or past [endDate] when that parses).
///
/// [when]'s time of day is ignored (truncated to the local date), so passing
/// `DateTime.now()` answers "which trip day is today?".
int? tripDayOn(String? startDate, String? endDate, DateTime when) {
  final start = DateTime.tryParse(startDate ?? '');
  if (start == null) return null;
  final date = DateTime(when.year, when.month, when.day);
  final day = date.difference(start).inDays + 1;
  if (day < 1) return null;
  final end = DateTime.tryParse(endDate ?? '');
  if (end != null && day > end.difference(start).inDays + 1) return null;
  return day;
}

/// Whether the trip is entirely behind [today]'s device-local calendar date:
/// its last day — [endDate], falling back to [startDate] for end-less trips —
/// is strictly before today. A trip ending today is not past; trips with no
/// parseable date at all are never past.
///
/// Deliberately diverges from [tripDayOn]'s "no end date means the trip never
/// ends once started" rule (which serves the live-trip spotlight): for list
/// grouping, a start-only trip whose start has gone by counts as past —
/// otherwise stale drafts would sit among upcoming trips forever. Callers that
/// also surface a live trip should exempt it rather than let the two rules
/// disagree about the same card.
bool tripIsPast(String? startDate, String? endDate, DateTime today) {
  final last =
      DateTime.tryParse(endDate ?? '') ?? DateTime.tryParse(startDate ?? '');
  if (last == null) return false;
  return DateTime(last.year, last.month, last.day)
      .isBefore(DateTime(today.year, today.month, today.day));
}

/// How many days a trip spans for day chips / pickers: the later of the
/// highest tagged day in [itemDays] and the [startDate]–[endDate] span (so an
/// empty dated trip still offers its real days, and an item tagged beyond the
/// span still gets a chip). 0 when the trip has neither dates nor tagged items.
int dayCount(String? startDate, String? endDate, Iterable<int?> itemDays) {
  var max = 0;
  for (final d in itemDays) {
    if (d != null && d > max) max = d;
  }
  final start = DateTime.tryParse(startDate ?? '');
  final end = DateTime.tryParse(endDate ?? '');
  if (start != null && end != null) {
    final span = end.difference(start).inDays + 1;
    if (span > max) max = span;
  }
  return max;
}

/// The set of 1-based days in `1..dayCount` that would plot something on the
/// trip map: days carried by a coordinate-bearing itinerary item, plus days
/// whose night is covered by a geocoded stay (checkout-exclusive, via
/// [stayCoversDate]). Callers pre-filter to mapped entries — pass only the
/// day tags of items with real coordinates and the date ranges of stays with
/// real coordinates. Lets day chips mute days that would show an empty map.
Set<int> daysWithMappedContent(
  String? startDate,
  int dayCount,
  Iterable<int?> mappedItemDays,
  Iterable<({String? checkIn, String? checkOut})> mappedStayDates,
) {
  final days = <int>{
    for (final d in mappedItemDays)
      if (d != null && d >= 1 && d <= dayCount) d,
  };
  final start = DateTime.tryParse(startDate ?? '');
  if (start != null) {
    for (var d = 1; d <= dayCount; d++) {
      if (days.contains(d)) continue;
      // Calendar-day arithmetic (constructor normalizes overflow) rather than
      // Duration, which drifts a date across a DST transition.
      final night = DateTime(start.year, start.month, start.day + d - 1);
      if (mappedStayDates
          .any((s) => stayCoversDate(s.checkIn, s.checkOut, night))) {
        days.add(d);
      }
    }
  }
  return days;
}

/// Whether a stay covers the night of [date] (device-local calendar date):
/// check-in <= date < check-out — **checkout-exclusive**, since nobody sleeps
/// there on checkout day. False when either date is missing or unparseable.
bool stayCoversDate(String? checkIn, String? checkOut, DateTime date) {
  final a = DateTime.tryParse(checkIn ?? '');
  final b = DateTime.tryParse(checkOut ?? '');
  if (a == null || b == null) return false;
  final d = DateTime(date.year, date.month, date.day);
  return !d.isBefore(DateTime(a.year, a.month, a.day)) &&
      d.isBefore(DateTime(b.year, b.month, b.day));
}
