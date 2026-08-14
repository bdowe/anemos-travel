// Insight facts derived from the GET /trips list payload
// (specs/trips-page-insights): lifetime aggregates, footprint pins, and the
// booking-urgency window. Pure and payload-only — every fact here has this
// file as its ONE derivation site; the server row is the one derivation for
// everything else (null fields ⇒ the UI hides, never recomputes locally).
// Ordering stays trip_list_order.dart's charter; date math stays
// trip_days.dart's.

import '../models/city_pin.dart';
import '../models/trip.dart';
import 'trip_days.dart';

/// All-time "Your travels" stats over the caller's OWNED trips (the caller
/// filters out shared-with-me rows): trip count, summed dated travel days
/// (undated trips contribute 0 via [dayCount]), and distinct hub cities
/// deduped case- and whitespace-insensitively.
({int trips, int travelDays, int cities}) lifetimeStats(List<Trip> trips) {
  var days = 0;
  final cities = <String>{};
  for (final t in trips) {
    days += dayCount(t.startDate, t.endDate, const <int?>[]);
    for (final c in t.cities ?? const <String>[]) {
      cities.add(c.trim().toLowerCase());
    }
  }
  return (trips: trips.length, travelDays: days, cities: cities.length);
}

/// Every located hub city across [trips] for the footprint map, flattened in
/// list order and deduped on the [lifetimeStats] city key — the FIRST
/// coordinate seen for a city wins, so revisits can't move a pin.
List<({String city, double lat, double lng})> footprintPins(List<Trip> trips) {
  final seen = <String>{};
  final pins = <({String city, double lat, double lng})>[];
  for (final t in trips) {
    for (final p in t.cityPins ?? const <CityPin>[]) {
      if (seen.add(p.city.trim().toLowerCase())) {
        pins.add((city: p.city, lat: p.lat, lng: p.lng));
      }
    }
  }
  return pins;
}

/// How close an unbooked first transport leg must be before the hero shows
/// the urgency nudge. Lives beside its one consumer, [bookingNudgeDate].
const kBookingNudgeWindowDays = 14;

/// The date the booking nudge warns about, or null when the card shows no
/// nudge. The server already guarantees [Trip.nextTransportDepart] is an
/// unbooked FUTURE transport departure; the client re-guards the window
/// against device-local today ([daysUntilTrip]'s UTC-normalized day diff),
/// so a stale cache can't nudge about a departed leg: 0 ≤ days-until ≤
/// [kBookingNudgeWindowDays].
DateTime? bookingNudgeDate(Trip trip, DateTime today) {
  final raw = trip.nextTransportDepart;
  final days = daysUntilTrip(raw, today);
  if (days == null || days > kBookingNudgeWindowDays) return null;
  return DateTime.parse(raw!); // non-null and parseable: days != null
}
