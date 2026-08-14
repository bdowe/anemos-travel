/// The trip's stated non-flight travel mode ('car'|'train'|'bus'|'ferry') when
/// it has one, else null.
///
/// 'flight', 'mixed' and unset all return null on purpose: 'mixed' means the
/// trip has no single mode (so a flight leg is still plausible) and unset is
/// the legacy default. Mirrors the server's reading of `trips.travel_mode`
/// (`allowedTravelModes` in trip_handler.go, and the same narrowing in
/// trip_review.go).
///
/// Derived in one place because two very different surfaces branch on it: the
/// booking-todo derivation (a ground trip books Rome2Rio routes, not flights)
/// and the map's home-airport leg (a saved home *airport* is a flying concept,
/// so it is not where a road trip starts).
String? groundTravelMode(String? travelMode) => switch (travelMode) {
      'car' || 'train' || 'bus' || 'ferry' => travelMode,
      _ => null,
    };
