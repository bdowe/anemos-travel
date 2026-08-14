import '../l10n/l10n.dart';

/// Canonical API values. These are sent to the server and read by the AI
/// agent, so they are NEVER translated — only their display labels are
/// (specs/i18n-spanish). Order is the curated display order: the original
/// ten first, then related interests adjacent.
///
/// Deliberately absent: `gym` and `running`. Those are the routine a traveler
/// keeps regardless of city, and they live in `TravelerPreferences
/// .fitnessRoutine` where they can actually change a stay recommendation —
/// duplicating them here would give one fact two homes (docs/zen.md).
/// Tastes that happen to be athletic (cycling, climbing) do belong here.
const suggestedInterests = [
  'museums',
  'food',
  'nightlife',
  'nature',
  'history',
  'art',
  'shopping',
  'outdoors',
  'beaches',
  'architecture',
  'live music',
  'bars',
  'theater',
  'festivals',
  'local markets',
  'street food',
  'coffee',
  'wine',
  'craft beer',
  'fine dining',
  'hiking',
  'wildlife',
  'water sports',
  'skiing',
  'cycling',
  'climbing',
  'national parks',
  'road trips',
  'photography',
  'street art',
  'wellness',
  'spas',
  'sports events',
];

/// Suggested interests get translated labels; anything the traveler typed
/// themselves is shown exactly as they wrote it.
String interestLabel(AppLocalizations l10n, String value) => switch (value) {
      'museums' => l10n.prefsInterestMuseums,
      'food' => l10n.prefsInterestFood,
      'nightlife' => l10n.prefsInterestNightlife,
      'nature' => l10n.prefsInterestNature,
      'history' => l10n.prefsInterestHistory,
      'art' => l10n.prefsInterestArt,
      'shopping' => l10n.prefsInterestShopping,
      'outdoors' => l10n.prefsInterestOutdoors,
      'beaches' => l10n.prefsInterestBeaches,
      'architecture' => l10n.prefsInterestArchitecture,
      'live music' => l10n.prefsInterestLiveMusic,
      'bars' => l10n.prefsInterestBars,
      'theater' => l10n.prefsInterestTheater,
      'festivals' => l10n.prefsInterestFestivals,
      'local markets' => l10n.prefsInterestLocalMarkets,
      'street food' => l10n.prefsInterestStreetFood,
      'coffee' => l10n.prefsInterestCoffee,
      'wine' => l10n.prefsInterestWine,
      'craft beer' => l10n.prefsInterestCraftBeer,
      'fine dining' => l10n.prefsInterestFineDining,
      'hiking' => l10n.prefsInterestHiking,
      'wildlife' => l10n.prefsInterestWildlife,
      'water sports' => l10n.prefsInterestWaterSports,
      'skiing' => l10n.prefsInterestSkiing,
      'cycling' => l10n.prefsInterestCycling,
      'climbing' => l10n.prefsInterestClimbing,
      'national parks' => l10n.prefsInterestNationalParks,
      'road trips' => l10n.prefsInterestRoadTrips,
      'photography' => l10n.prefsInterestPhotography,
      'street art' => l10n.prefsInterestStreetArt,
      'wellness' => l10n.prefsInterestWellness,
      'spas' => l10n.prefsInterestSpas,
      'sports events' => l10n.prefsInterestSportsEvents,
      _ => value,
    };
