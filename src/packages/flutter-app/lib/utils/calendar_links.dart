import '../l10n/app_localizations.dart';
import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../models/trip_segment.dart';

/// Builders for the per-event "Add to calendar" affordance.
///
/// Google Calendar takes a prefilled calendar.google.com link built entirely
/// client-side (no server round-trip, no OAuth); Apple Calendar goes through
/// the token-gated per-event .ics endpoint instead (see exportEventIcsUrl in
/// share_link.dart). Both buttons sit on the same rows, so these resolvers
/// mirror the Go export semantics (calendar_handler.go) field for field —
/// ends are EXCLUSIVE, a null range means "undated, hide the affordance",
/// stays and transport are all-day, and itinerary items become TIMED events
/// from their time_of_day bucket. Change either side and you must change both.

/// Prefilled Google Calendar event link. All-day by default; [allDay] false
/// emits floating local date-times so the event lands at the same wall clock
/// as the .ics.
String googleCalendarUrl({
  required String title,
  required DateTime start,
  required DateTime endExclusive,
  bool allDay = true,
  String? location,
  String? details,
}) {
  return Uri.https('calendar.google.com', '/calendar/render', {
    'action': 'TEMPLATE',
    'text': title,
    'dates': allDay
        ? '${_ymd(start)}/${_ymd(endExclusive)}'
        : '${_ymdhms(start)}/${_ymdhms(endExclusive)}',
    if (location != null && location.trim().isNotEmpty) 'location': location,
    if (details != null && details.trim().isNotEmpty) 'details': details,
  }).toString();
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}'
    '${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';

/// Floating local date-time. Deliberately NO trailing "Z": a Z would make
/// Google read the pair as UTC and shift the event by the viewer's offset,
/// breaking parity with the floating .ics (icsDateTimeLayout in Go).
String _ymdhms(DateTime d) => '${_ymd(d)}T'
    '${d.hour.toString().padLeft(2, '0')}'
    '${d.minute.toString().padLeft(2, '0')}'
    '${d.second.toString().padLeft(2, '0')}';

/// A stay spans check-in through check-out (one night when check-out is
/// missing or not after check-in). Null when check-in is missing/unparseable.
({DateTime start, DateTime endExclusive, bool allDay})? stayCalendarRange(
    Accommodation a) {
  final start = _parseDate(a.checkIn);
  if (start == null) return null;
  final checkOut = _parseDate(a.checkOut);
  final end = (checkOut != null && checkOut.isAfter(start))
      ? checkOut
      : start.add(const Duration(days: 1));
  return (start: start, endExclusive: end, allDay: true);
}

/// A segment spans departure day through arrival day inclusive (a single day
/// when arrival is missing). Null when the departure date is missing.
({DateTime start, DateTime endExclusive, bool allDay})? segmentCalendarRange(
    TripSegment s) {
  final start = _parseDate(s.departDate);
  if (start == null) return null;
  final arrive = _parseDate(s.arriveDate);
  final end = (arrive != null && arrive.isAfter(start))
      ? arrive.add(const Duration(days: 1))
      : start.add(const Duration(days: 1));
  return (start: start, endExclusive: end, allDay: true);
}

/// An itinerary item occupies the single trip day it's assigned to:
/// trip.start_date + (day - 1). With a [timeOfDay] bucket it becomes a timed
/// event; without one it stays all-day. Null without a trip start date or day.
({DateTime start, DateTime endExclusive, bool allDay})? itemCalendarRange(
  String? tripStartDate,
  int? day, {
  String? timeOfDay,
}) {
  final tripStart = _parseDate(tripStartDate);
  if (tripStart == null || day == null || day < 1) return null;
  // Day arithmetic stays on UTC midnights — see _parseDate.
  final dayStart = tripStart.add(Duration(days: day - 1));

  final window = _itemTimeWindow(timeOfDay);
  if (window == null) {
    return (
      start: dayStart,
      endExclusive: dayStart.add(const Duration(days: 1)),
      allDay: true,
    );
  }
  // Rebuild with the hour rather than adding a Duration: these values are
  // wall-clock carriers, not instants (see _parseDate).
  return (
    start: DateTime.utc(
        dayStart.year, dayStart.month, dayStart.day, window.startHour),
    endExclusive:
        DateTime.utc(dayStart.year, dayStart.month, dayStart.day, window.endHour),
    allDay: false,
  );
}

/// morning 09–12, afternoon 13–17, evening 19–22; null for an empty or
/// unrecognized bucket (the item stays all-day). Mirrors itemTimeWindow in
/// calendar_handler.go — the two MUST move together.
({int startHour, int endHour})? _itemTimeWindow(String? timeOfDay) =>
    switch (timeOfDay?.trim().toLowerCase()) {
      'morning' => (startHour: 9, endHour: 12),
      'afternoon' => (startHour: 13, endHour: 17),
      'evening' => (startHour: 19, endHour: 22),
      _ => null,
    };

/// Calendar event title for a transport segment.
///
/// This MUST stay byte-identical to the Go `.ics` export
/// (calendar_handler.go `segmentEventFieldsIn`): the traveler picks between
/// a Google Calendar link built here and an `.ics` file built there for the
/// SAME event, so any divergence shows up as two differently-named entries.
/// That is why the empty-route case falls back to the mode label rather than
/// returning the mode alone, matching Go's `segmentRouteIn`.
String segmentCalendarTitle(AppLocalizations l10n, TripSegment s) {
  final mode = calendarModeLabel(l10n, s.mode);
  final route = [s.origin, s.destination].whereType<String>().join(' → ');
  return l10n.calendarSegmentTitle(mode, route.isEmpty ? mode : route);
}

/// Mirrors Go's `localizedMode`: known modes translate, anything else keeps
/// its raw value capitalized.
String calendarModeLabel(AppLocalizations l10n, String mode) =>
    switch (mode.trim().toLowerCase()) {
      'flight' => l10n.calendarModeFlight,
      'train' => l10n.calendarModeTrain,
      'bus' => l10n.calendarModeBus,
      'car' => l10n.calendarModeCar,
      'ferry' => l10n.calendarModeFerry,
      'other' => l10n.calendarModeOther,
      '' => '',
      _ => mode[0].toUpperCase() + mode.substring(1),
    };

/// Calendar details for a stay, mirroring icsStayDescription: provider, price
/// note, booked flag, and the readable booking link.
String stayCalendarDetails(AppLocalizations l10n, Accommodation a) =>
    _detailParts([
      a.provider,
      a.priceNote,
      if (a.booked) l10n.bookingCardBooked,
      displayUrl(a.url),
    ]);

/// Calendar details for a transport segment, mirroring icsSegmentDescription.
String segmentCalendarDetails(AppLocalizations l10n, TripSegment s) =>
    _detailParts([
      s.provider,
      s.priceNote,
      if (s.booked) l10n.bookingCardBooked,
      s.notes,
      displayUrl(s.url),
    ]);

/// Calendar details for an itinerary item, mirroring icsItemDescription:
/// time-of-day + local attribution.
String itemCalendarDetails(AppLocalizations l10n, ItineraryItem item) {
  final tod = item.timeOfDay;
  final rec = item.localSourceName?.trim();
  return _detailParts([
    if (tod != null && tod.isNotEmpty) tod[0].toUpperCase() + tod.substring(1),
    if (rec != null && rec.isNotEmpty) l10n.tripRecommendedBy(rec),
  ]);
}

/// Joins the non-empty parts so a missing field never leaves a dangling
/// separator (mirrors icsDetailParts in Go).
String _detailParts(List<String?> vals) => vals
    .map((v) => v?.trim() ?? '')
    .where((v) => v.isNotEmpty)
    .join(' · ');

/// Readable form of a booking link for calendar text: host + path, no scheme,
/// "www.", query, or fragment, truncated. Mirrors displayURL in
/// print_view_handler.go.
String displayUrl(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  var display = trimmed;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) {
    final host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
    var path = uri.path;
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    display = '$host$path';
  }
  const maxRunes = 48;
  final runes = display.runes.toList();
  if (runes.length > maxRunes) {
    return '${String.fromCharCodes(runes.take(maxRunes - 1))}…';
  }
  return display;
}

/// Parses a YYYY-MM-DD date to UTC midnight. UTC keeps the day arithmetic
/// above exact — adding Duration(days: 1) to a LOCAL DateTime shifts by an
/// hour across DST boundaries (see the Today-mode calendar-math lesson).
/// These DateTimes are never instants: they are wall-clock carriers, emitted
/// without a zone, so they stay floating like the .ics.
DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  final t = DateTime.tryParse(s);
  if (t == null) return null;
  return DateTime.utc(t.year, t.month, t.day);
}
