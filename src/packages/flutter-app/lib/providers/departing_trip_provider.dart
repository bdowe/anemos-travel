import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip.dart';
import '../utils/trip_days.dart';
import 'live_trip_provider.dart';
import 'trips_provider.dart';

/// How close departure has to be for Home to raise readiness. Two weeks is the
/// span where lodging, transport and packing stop being plans and start being
/// errands.
///
/// The ONE owner of that window. [BeforeYouGoSection] used to re-check it
/// itself against whatever trip it was handed; now the selection below decides
/// which trip qualifies, so the widget never has to ask again and the two
/// cannot drift apart on the answer.
const int kBeforeYouGoWindowDays = 14;

/// The trip Home raises pre-departure readiness for, or null when none is
/// close enough.
typedef DepartingTrip = ({
  String tripId,
  String title,
  String? startDate,
  int daysUntil,
});

/// The trip [BeforeYouGoSection] is about: **the one departing soonest**
/// within [kBeforeYouGoWindowDays], not the one this device happened to open
/// last.
///
/// That distinction is the whole point of this selector. The section used to
/// ride `continueTripOf`, whose job is "offer a way back in" — it answers with
/// the last trip you VIEWED, falling back to the most recently UPDATED one.
/// Neither key is departure. So a traveler with two trips who opened the
/// October one to rename it got October's readiness on Home while the trip
/// leaving on Friday said nothing, and the header named no trip, so there was
/// nothing on screen to reveal the swap. Ordering on `daysUntil` makes the
/// section's subject the same trip the traveler means by "before you go", and
/// [BeforeYouGoSection] now prints its name either way.
///
/// [liveTrip] is excluded, matching [continueTripOf] and for the same reason
/// plus one of its own: it already has [LiveTripCard] above, and a trip you are
/// ON is not a trip you are about to take. That exclusion has to be explicit,
/// because [daysUntilTrip] answers 0 — not null — for a trip that starts today,
/// which is exactly the trip [liveTripOf] claims.
///
/// Undated trips never qualify: [daysUntilTrip] returns null for them, and a
/// readiness list with no departure to be ready for is a nag, not a signal.
/// Past trips are excluded by the same call (a start already behind [today] is
/// null), so no separate [tripIsPast] check is needed.
///
/// Exact ties on the departure date — two trips leaving the same morning — go
/// to the more recently touched one, the [continueTripOf] tie-break, on the
/// grounds that it is the one being actively planned. Pure and static so the
/// choice can be unit-tested without a harness.
DepartingTrip? departingTripOf(
  List<Trip> trips,
  Trip? liveTrip,
  DateTime today,
) {
  Trip? best;
  int? bestDays;
  for (final t in trips) {
    if (t.id == liveTrip?.id) continue;
    final days = daysUntilTrip(t.startDate, today);
    if (days == null || days > kBeforeYouGoWindowDays) continue;
    if (bestDays == null ||
        days < bestDays ||
        // updatedAt is a required ISO-8601 string off the wire, so
        // lexicographic order is chronological order — the convention
        // trip_list_order.dart and continueTripOf both sort by.
        (days == bestDays && t.updatedAt.compareTo(best!.updatedAt) > 0)) {
      best = t;
      bestDays = days;
    }
  }
  if (best == null || bestDays == null) return null;
  return (
    tripId: best.id,
    title: best.title,
    startDate: best.startDate,
    daysUntil: bestDays,
  );
}

/// The trip Home's "Before you go" section reports on — see [departingTripOf]
/// for which trip that is and why it is not the continue-trip.
///
/// Returns a record, so the recompute that every trips refresh triggers only
/// rebuilds Home when the answer actually changed — the narrow-watch doctrine
/// the home screen documents at the top of its build.
///
/// "Now" is sampled at build time, exactly like [liveTripProvider] and
/// [continueTripProvider]: a trip that ages into the window at midnight shows
/// up on the next list refresh rather than spontaneously.
final departingTripProvider = Provider<DepartingTrip?>((ref) {
  final trips = ref.watch(tripsProvider.select((s) => s.trips));
  final liveTrip = ref.watch(liveTripProvider);
  return departingTripOf(trips, liveTrip, DateTime.now());
});
