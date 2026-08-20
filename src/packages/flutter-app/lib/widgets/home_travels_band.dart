import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/trips_provider.dart';
import '../theme/spacing.dart';
import '../utils/trip_list_insights.dart';
import 'section_header.dart';
import 'travel_footprint_card.dart';

/// "Your travels" on Home: the traveled/planned footprint the Trips tab
/// already shows, so the page ends on where you have been rather than on
/// nothing.
///
/// Reuses [TravelFootprintCard] and [travelStats] outright rather than
/// restating them — a second arithmetic for the same two counts is how the two
/// surfaces would start disagreeing about how many cities you have visited.
/// Both gates come with it: **2+ owned trips**, because an aggregate over one
/// trip only restates the hero above it, and the card's own pin rules.
///
/// Reads `tripsProvider`, which is populated app-wide (the shell keeps
/// `TripsListScreen` mounted and its `loadTrips()` feeds it), so this costs no
/// request of its own — the same reason Home can watch it for `returning`.
///
/// Owned trips only. Shared-with-me is someone else's travel and its payload
/// carries no pins anyway, which is the rule the Trips tab already applies.
class HomeTravelsBand extends ConsumerWidget {
  const HomeTravelsBand({super.key});

  /// Below this an aggregate says nothing the trip cards above have not.
  static const int _minTrips = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Length only, not the trip objects: a background refresh rebuilds every
    // Trip, and this band's numbers only change when the SET does. The full
    // list is read below, once the length says this build runs anyway.
    final tripCount = ref.watch(tripsProvider.select((s) => s.trips.length));
    if (tripCount < _minTrips) return const SizedBox.shrink();

    final trips = ref.read(tripsProvider).trips;
    final now = DateTime.now();
    final stats = travelStats(trips, now);
    final pins = footprintPins(trips, now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: context.l10n.tripsListYourTravels),
        const SizedBox(height: AppSpacing.md),
        TravelFootprintCard(
          pins: pins,
          traveled: stats.traveled,
          planned: stats.planned,
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}
