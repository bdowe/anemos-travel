import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../models/flight_offer.dart';

/// Stop-count, cabin and date labels for flight surfaces (specs/i18n-spanish).
///
/// These live here rather than on [FlightOffer] because they are prose, and
/// Spanish pluralizes differently ("1 escala" / "2 escalas") — a model getter
/// returning a fixed English sentence can't express that. Duration labels stay
/// on the model: "7h 30m" is a unit abbreviation, not copy.

/// Localized display label for a canonical cabin-class API value
/// (`economy` / `premium_economy` / `business` / `first`). The values sent to
/// the Duffel-backed API are NEVER translated — only this display label is
/// (specs/i18n-spanish). Unknown values render as-is so a new backend value
/// never blanks a card. Shared by the flight search and details surfaces.
String cabinClassLabel(AppLocalizations l10n, String value) => switch (value) {
      'economy' => l10n.flightSearchCabinEconomy,
      'premium_economy' => l10n.flightSearchCabinPremiumEconomy,
      'business' => l10n.flightSearchCabinBusiness,
      'first' => l10n.flightSearchCabinFirst,
      _ => value,
    };

/// Short localized display date ("Sep 1" / "1 sept") for a machine-facing
/// `YYYY-MM-DD` string. Falls back to the raw string when unparseable so a
/// malformed API date degrades to ISO instead of crashing the card.
String flightDateLabel(AppLocalizations l10n, String isoDate) {
  final d = DateTime.tryParse(isoDate);
  if (d == null) return isoDate;
  return DateFormat.MMMd(l10n.localeName).format(d);
}

/// "Nonstop" / "1 stop" / "N stops".
String stopsLabel(AppLocalizations l10n, int stops) => l10n.flightStops(stops);

/// One label covering both directions of a round trip — "Nonstop",
/// "1 stop each way", or "Nonstop / 1 stop" when the directions differ.
/// Falls back to the one-way label for one-way offers.
String combinedStopsLabel(AppLocalizations l10n, FlightOffer offer) {
  if (!offer.isRoundTrip) return stopsLabel(l10n, offer.stops);
  if (offer.stops == offer.returnStops) {
    return offer.stops == 0
        ? stopsLabel(l10n, 0)
        : l10n.flightStopsEachWay(stopsLabel(l10n, offer.stops));
  }
  return l10n.flightStopsSplit(
      stopsLabel(l10n, offer.stops), stopsLabel(l10n, offer.returnStops));
}
