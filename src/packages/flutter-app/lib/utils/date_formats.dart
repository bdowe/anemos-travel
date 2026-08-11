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

void _syncLocale() {
  final tag = Intl.defaultLocale;
  if (tag != _cachedLocaleTag) {
    _cachedLocaleTag = tag;
    _mmmd = null;
    _mmmed = null;
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

/// "Jul 15 – Jul 18" via [mmmd], collapsing a same-day pair to the single
/// date. The one shared range shape: the trip header, city-header date chips,
/// booking-todo subtitles, and map destination pins all speak this.
String formatShortRange(DateTime a, DateTime b) {
  final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
  final f = mmmd();
  return sameDay ? f.format(a) : '${f.format(a)} – ${f.format(b)}';
}
