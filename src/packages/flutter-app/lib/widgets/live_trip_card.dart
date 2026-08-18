import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../utils/trip_days.dart';
import 'trip_hero_card.dart';

/// The trip that is happening right now, promoted to the head of the trips
/// list and to Home's live slot (specs/happening-now). Tap goes straight to
/// the trip detail, which auto-scrolls to today.
///
/// It REPLACES the trip's plain list card — a promoted trip is never listed
/// twice. It used to sit above the list AND stay in it ("a shortcut, not a
/// filter"), which was defensible while the list below was one flat run
/// called "My Trips" and this card carried nothing the row did; once the list
/// grew sections, that left a trip already under way filed under "Upcoming".
/// The card earns the replacement by carrying the row's facts: [TripHeroCard]
/// is the shared body, and everything below is the two-line difference
/// between this hero and the pre-trip one, [UpNextTripCard].
class LiveTripCard extends StatelessWidget {
  final Trip trip;
  final VoidCallback onTap;

  /// Passed through to [TripHeroCard.showMap]. Home passes false: its copy of
  /// this card and the trips list's are alive at the same time inside
  /// AppShell's IndexedStack, and two route bands for one trip starve each
  /// other's tiles until both render blank.
  final bool showMap;

  const LiveTripCard(
      {super.key,
      required this.trip,
      required this.onTap,
      this.showMap = true});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    // Where the trip stands today: "Day N of M", or just "Day N" for an
    // open-ended trip (no end date => day count 0). The trips-list payload
    // carries no items, so the count comes from the date span alone.
    final day = tripDayOn(trip.startDate, trip.endDate, DateTime.now());
    final total = dayCount(trip.startDate, trip.endDate, const <int?>[]);
    final progress = day == null
        ? null
        : (total > 0 ? l10n.liveTripDayOfTotal(day, total) : l10n.liveTripDay(day));

    return TripHeroCard(
      trip: trip,
      // No date square: the Live pill leads, and today's date is filler —
      // the pre-trip hero is the one anchored to a calendar day.
      // "Day 2 of 5" already names the span, so the card's own duration label
      // would be a second total saying the same thing.
      showDuration: false,
      showMap: showMap,
      leadingMeta: [
        TripHeroCard.heroPill(context, l10n.liveTripStatusLive),
        if (progress != null) TripHeroCard.heroFact(context, progress),
      ],
      onTap: onTap,
    );
  }
}
