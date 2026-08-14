// Insight facts derived from the GET /trips list payload
// (specs/trips-page-insights): the traveled/planned travel aggregates,
// footprint pins, and the booking-urgency window. Pure and payload-only —
// every fact here has this file as its ONE derivation site; the server row is
// the one derivation for everything else (null fields ⇒ the UI hides, never
// recomputes locally). Ordering stays trip_list_order.dart's charter; date
// math stays trip_days.dart's.

import '../models/city_pin.dart';
import '../models/trip.dart';
import 'trip_days.dart';

/// One side of the "Your travels" split: trip count, travel days, and distinct
/// hub cities.
typedef TravelStats = ({int trips, int travelDays, int cities});

/// "Your travels" over the caller's OWNED trips (the caller filters out
/// shared-with-me rows), split into what has been TRAVELED and what is still
/// PLANNED. The band used to report one all-time total, which counted a trip
/// that starts next month as travel already taken — the section sits where the
/// page turns from plans to history, so its numbers have to say which is which.
///
/// Every trip lands on exactly one side, so under the card's 2+ owned trips
/// gate at least one side always has something to show:
///
/// - **Trips** — traveled once the trip has started ([tripHasStarted]); future
///   trips and undated drafts are planned.
/// - **Travel days** — traveled counts only days already lived through
///   ([traveledDayCount]), so an in-progress trip's counter ticks up daily
///   instead of banking all 35 days on day one; planned counts the full span
///   ([dayCount]) of trips that haven't started. The remaining days of an
///   in-progress trip land on neither side: each side stays internally
///   consistent with the trips shown beside it, which is the arithmetic a
///   reader can actually check, and the old grand total is no longer on screen.
/// - **Cities** — deduped case- and whitespace-insensitively, with **traveled
///   winning** the overlap, so a city on both a past and a future trip counts
///   once and counts as visited. The two counts partition rather than
///   double-count, matching the map's two pin styles.
({TravelStats traveled, TravelStats planned}) travelStats(
    List<Trip> trips, DateTime today) {
  var traveledTrips = 0;
  var traveledDays = 0;
  var plannedTrips = 0;
  var plannedDays = 0;
  final traveledCities = <String>{};
  final plannedCities = <String>{};
  for (final t in trips) {
    final started = tripHasStarted(t.startDate, t.endDate, today);
    for (final c in t.cities ?? const <String>[]) {
      (started ? traveledCities : plannedCities).add(_cityKey(c));
    }
    if (started) {
      traveledTrips++;
      traveledDays += traveledDayCount(t.startDate, t.endDate, today);
    } else {
      plannedTrips++;
      plannedDays += dayCount(t.startDate, t.endDate, const <int?>[]);
    }
  }
  // Resolved after the loop, not inside it: server order is
  // newest-created-first, so a city is routinely seen on a planned trip before
  // the past trip that visited it shows up.
  plannedCities.removeAll(traveledCities);
  return (
    traveled: (
      trips: traveledTrips,
      travelDays: traveledDays,
      cities: traveledCities.length,
    ),
    planned: (
      trips: plannedTrips,
      travelDays: plannedDays,
      cities: plannedCities.length,
    ),
  );
}

/// One dot on the footprint map: a located hub city, and whether the traveler
/// has actually been there.
typedef FootprintPin = ({String city, double lat, double lng, bool visited});

/// Every located hub city across [trips] for the footprint map, flattened in
/// list order and deduped on the [travelStats] city key — the FIRST coordinate
/// seen for a city wins, so revisits can't move a pin.
///
/// [visited] is read from the set of cities on trips that have STARTED, never
/// from whichever trip supplied the winning coordinate: with the list in
/// newest-created-first order a planned trip routinely lands ahead of the past
/// trip that visited the same city, and taking the flag off the coordinate's
/// own row would hollow out pins the traveler has already earned.
List<FootprintPin> footprintPins(List<Trip> trips, DateTime today) {
  final visited = <String>{};
  for (final t in trips) {
    if (!tripHasStarted(t.startDate, t.endDate, today)) continue;
    // Pins are a subset of cities on the wire (one server lateral emits both),
    // but this function is keyed on the PIN list — reading the flag out of
    // cities alone would make it depend on a sibling field being populated,
    // and a row that somehow carried pins without cities would render every
    // dot as unvisited. Union, so the flag stands on its own.
    for (final c in t.cities ?? const <String>[]) {
      visited.add(_cityKey(c));
    }
    for (final p in t.cityPins ?? const <CityPin>[]) {
      visited.add(_cityKey(p.city));
    }
  }
  final seen = <String>{};
  final pins = <FootprintPin>[];
  for (final t in trips) {
    for (final p in t.cityPins ?? const <CityPin>[]) {
      final key = _cityKey(p.city);
      if (seen.add(key)) {
        pins.add((
          city: p.city,
          lat: p.lat,
          lng: p.lng,
          visited: visited.contains(key),
        ));
      }
    }
  }
  return pins;
}

/// The dedupe key both derivations share, so " lisbon " and "Lisbon" are one
/// city on the tiles and one dot on the map.
String _cityKey(String city) => city.trim().toLowerCase();

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
