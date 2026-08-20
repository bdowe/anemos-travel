// Cached, locale-keyed [DateFormat] instances for the app's two display date
// shapes ("Jul 15" / "Wed, Jul 15"), so hot render paths don't re-construct a
// DateFormat — a symbol-table lookup — per formatted date per build
// (specs/perf-program, Wave 4 PR1).
//
// DateFormat reads Intl.defaultLocale, which the locale provider sets
// (specs/i18n-spanish). The cache is keyed on that tag: the first call after
// a locale change drops both cached instances and rebuilds them under the new
// locale, so callers can never format with a stale language. Outside a
// Flutter app (pure unit tests) intl falls back to en_US, same as before.

import 'package:intl/intl.dart';

String? _cachedLocaleTag;
DateFormat? _mmmd;
DateFormat? _mmmed;
DateFormat? _e;
DateFormat? _d;
DateFormat? _ymmmm;
List<String>? _weekdayHeaders;

void _syncLocale() {
  final tag = Intl.defaultLocale;
  if (tag != _cachedLocaleTag) {
    _cachedLocaleTag = tag;
    _mmmd = null;
    _mmmed = null;
    _e = null;
    _d = null;
    _ymmmm = null;
    _weekdayHeaders = null;
  }
}

/// `DateFormat.MMMd()` for the current `Intl.defaultLocale` — "Jul 15" in
/// English, "15 jul" in Spanish.
DateFormat mmmd() {
  _syncLocale();
  return _mmmd ??= DateFormat.MMMd();
}

/// `DateFormat.MMMEd()` for the current `Intl.defaultLocale` — "Wed, Jul 15"
/// in English; Spanish reorders to "mié, 15 jul" on its own.
DateFormat mmmed() {
  _syncLocale();
  return _mmmed ??= DateFormat.MMMEd();
}

/// "Sat 29" — abbreviated weekday plus day of month, for the narrow trip-detail
/// day header, where the city header directly above already states the month.
///
/// Composed from the two sub-patterns rather than asked for as a skeleton
/// because **intl ships no `Ed` pattern**: it is absent from every locale in
/// `data/dates/patterns/`, so `DateFormat.Ed()` does not exist. Both shipped
/// locales lead with the weekday for this pair (`en: EEE, MMM d`,
/// `es: EEE, d MMM`), so one order is right for both — revisit when adding a
/// locale that puts the day first.
String weekdayDay(DateTime date) {
  _syncLocale();
  final e = _e ??= DateFormat.E();
  final d = _d ??= DateFormat.d();
  return '${e.format(date)} ${d.format(date)}';
}

/// "Jul 15 – Jul 18" via [mmmd], collapsing a same-day pair to the single
/// date. The one shared range shape: the trip header, city-header date chips,
/// booking-todo subtitles, and map destination pins all speak this.
String formatShortRange(DateTime a, DateTime b) {
  final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
  final f = mmmd();
  return sameDay ? f.format(a) : '${f.format(a)} – ${f.format(b)}';
}

/// `DateFormat.yMMMM()` for the current `Intl.defaultLocale` — "August 2026"
/// in English, "agosto de 2026" in Spanish. Month-grid headings (the trip
/// calendar sheet).
DateFormat ymmmm() {
  _syncLocale();
  return _ymmmm ??= DateFormat.yMMMM();
}

/// "Sat, Aug 29 – Thu, Sep 3" via [mmmed], collapsing a same-day pair to the
/// single date. The weekday-carrying sibling of [formatShortRange]: the trip
/// calendar's leg detail row, where weekday-vs-weekend is the whole point of
/// the surface.
String formatWeekdayRange(DateTime a, DateTime b) {
  final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
  final f = mmmed();
  return sameDay ? f.format(a) : '${f.format(a)} – ${f.format(b)}';
}

/// The seven column headings of a Monday-first week grid, MON..SUN in
/// English: the locale's abbreviated weekday names, uppercased (the caps
/// come from the string, the wordmark rule) with any trailing period
/// stripped (some CLDR locales abbreviate with one, e.g. an older "lun.").
List<String> weekdayHeaders() {
  _syncLocale();
  final cached = _weekdayHeaders;
  if (cached != null) return cached;
  final e = _e ??= DateFormat.E();
  // 2024-01-01 was a Monday, so +i walks Mon..Sun.
  return _weekdayHeaders = [
    for (var i = 0; i < 7; i++)
      e.format(DateTime(2024, 1, 1 + i)).replaceAll('.', '').toUpperCase(),
  ];
}
