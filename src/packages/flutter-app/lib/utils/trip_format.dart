// Shared trip-formatting helpers so the trips list, the home recent-trip tile,
// and the trip-detail header all speak the same language.
//
// Dates go through intl's DateFormat, which reads Intl.defaultLocale — set by
// the locale provider (specs/i18n-spanish) — so month names and day/month
// ordering follow the app's language without any call site passing a locale.
// flutter_localizations loads the date symbols for the active locale before
// first paint; outside a Flutter app (unit tests) intl falls back to en_US.

import '../l10n/l10n.dart';
import 'date_formats.dart';

/// "Mon d" from an already-parsed date — [shortDateLabel]'s shape for callers
/// that hold a DateTime, so a caller that derived a date never has to re-parse
/// the ISO string to display it.
String shortDateOf(DateTime d) => mmmd().format(d);

/// "Mon d – Mon d" from ISO start/end (same day collapses to one); null when
/// either date is missing or unparseable.
String? tripDateRange(String? startIso, String? endIso) {
  final a = DateTime.tryParse(startIso ?? '');
  final b = DateTime.tryParse(endIso ?? '');
  if (a == null || b == null) return null;
  return formatShortRange(a, b);
}

/// "Mon d" from a single ISO date; null when missing or unparseable.
String? shortDateLabel(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  return d == null ? null : shortDateOf(d);
}

/// The ONE date line for a transport leg. A leg occupies two calendar days
/// whenever it lands after the day it left — an overnight flight, a red-eye, a
/// night train, an overnight ferry — and the app has to be able to say so:
///
///   * both dates, different   -> "Aug 23 → Aug 24"
///   * departure known         -> "Aug 23"
///   * only the arrival known  -> "Arrives Aug 24"
///   * neither                 -> null
///
/// The last case is the honest one that used to be missing. A bare "Aug 24"
/// under "EWR → Amsterdam" has exactly one reading — this is the day you fly —
/// and for a transatlantic red-eye that reading is false. Labelling it as an
/// arrival asserts only what the itinerary actually knows: the day the traveler
/// is first in Amsterdam.
///
/// Shared by the derived checklist row (trip_detail_screen `_deriveTodos`) and
/// the confirmed-segment row beneath it (BookingDetailRow) so the two can never
/// print different dates for the same leg.
String? transportDateLineOf(
    AppLocalizations l10n, DateTime? depart, DateTime? arrive) {
  if (depart != null && arrive != null && arrive != depart) {
    return l10n.bookingRowDepartArrive(
        shortDateOf(depart), shortDateOf(arrive));
  }
  if (depart != null) return shortDateOf(depart);
  if (arrive != null) return l10n.bookingRowArrivesOn(shortDateOf(arrive));
  return null;
}

/// [transportDateLineOf] from ISO strings, for callers holding wire values.
String? transportDateLine(
        AppLocalizations l10n, String? departIso, String? arriveIso) =>
    transportDateLineOf(l10n, DateTime.tryParse(departIso ?? ''),
        DateTime.tryParse(arriveIso ?? ''));

/// A stored title is "long" when it's really the AI summary (multi-line or
/// lengthy); such trips show a cities-derived display title instead. Shared by
/// the trip-detail header, the trips list, and the home live-trip tile so the
/// same trip never flips names between screens.
bool tripTitleIsLong(String title) => title.contains('\n') || title.length > 60;

/// The one display-title rule for trip cards ([tripTitleIsLong] applied): the
/// trip's own title unless it's really the AI summary, then the [cities]
/// label, then the raw title as a last resort. Shared by the trips list card,
/// the live-trip tile, and the "Up next" hero so the same trip never flips
/// names between cards. A card showing a separate cities line should suppress
/// it when this returns the cities label itself.
String tripHeadline(String title, String? cities) =>
    title.isNotEmpty && !tripTitleIsLong(title) ? title : (cities ?? title);

/// A short destination summary from a trip's hub cities: "Paris",
/// "Mexico City & Puerto Vallarta", or "Tokyo & Kyoto +2 more". Null when
/// there is no city data (legacy trips), so callers fall back to the title.
///
/// The two multi-city shapes are joined with translated connectors, so callers
/// pass the [AppLocalizations]-backed strings in. They stay optional: callers
/// without a BuildContext (and the tests) get the English forms.
String? citiesLabel(
  List<String>? cities, {
  String Function(String first, String second)? two,
  String Function(String first, String second, int count)? more,
}) {
  final c = cities ?? const <String>[];
  if (c.isEmpty) return null;
  if (c.length == 1) return c.first;
  if (c.length == 2) {
    return two?.call(c[0], c[1]) ?? '${c[0]} & ${c[1]}';
  }
  final remaining = c.length - 2;
  return more?.call(c[0], c[1], remaining) ??
      '${c[0]} & ${c[1]} +$remaining more';
}

/// "YYYY-MM-DD" from an ISO timestamp, falling back to the raw value.
/// Deliberately NOT localized: this is a machine-facing key (API params, map
/// lookups), not display text.
String shortDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
