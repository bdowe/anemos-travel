import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../utils/trip_days.dart';
import 'trip_hero_card.dart';

/// The soonest upcoming trip, promoted to a hero at the head of the trips
/// list — the pre-trip sibling of [LiveTripCard], with a countdown pill
/// instead of a Live pill. Like it, the hero REPLACES the trip's plain list
/// card, and it never renders while a live trip exists — one promoted object
/// at a time. The shared body (and the reason a hero may replace a card at
/// all) lives in [TripHeroCard].
class UpNextTripCard extends StatelessWidget {
  final Trip trip;
  final VoidCallback onTap;

  const UpNextTripCard({super.key, required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Promoted ⇔ daysUntilTrip is non-null (upNextTrip's own rule), so the
    // pill can never disagree with the promotion that put the card here.
    final days = daysUntilTrip(trip.startDate, DateTime.now());

    return TripHeroCard(
      trip: trip,
      eyebrow: l10n.upNextEyebrow,
      icon: Icons.flight_takeoff,
      leadingMeta: [
        if (days != null) TripHeroCard.heroPill(l10n.upNextStartsIn(days)),
      ],
      onTap: onTap,
    );
  }
}
