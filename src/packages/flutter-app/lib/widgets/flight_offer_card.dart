import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/flight_labels.dart';
import '../models/flight_leg.dart';
import '../models/flight_offer.dart';
import '../utils/money_format.dart';
import '../utils/tracked_launch.dart';
import 'airline_logo.dart';
import 'flight_details_sheet.dart';
import 'status_pill.dart';
import '../utils/snack.dart';

/// "Saves USD 23 vs next option" for the best-ranked offer on a baggage-aware
/// search, comparing effective totals (fare + bag fee). Null when there is
/// nothing honest to claim: bare-fare searches, an unpriceable bag on the best
/// offer, no comparable alternative (unknown fees and other currencies are
/// skipped — their totals understate or don't compare), or a saving that would
/// round to zero.
String? savingsLabelFor(
    AppLocalizations l10n, List<FlightOffer> offers, String? bestOfferId) {
  FlightOffer? best;
  for (final o in offers) {
    if (o.id == bestOfferId) {
      best = o;
      break;
    }
  }
  if (best == null || best.baggageStatus == null || best.bagFeeUnknown) {
    return null;
  }
  double? nextBest;
  for (final o in offers) {
    if (o.id == best.id || o.bagFeeUnknown || o.currency != best.currency) {
      continue;
    }
    if (nextBest == null || o.displayPrice < nextBest) {
      nextBest = o.displayPrice;
    }
  }
  if (nextBest == null) return null;
  final saved = nextBest - best.displayPrice;
  if (saved < 0.5) return null;
  return l10n.flightCardSavings(formatMoney(saved, best.currency));
}

/// A single ranked flight offer rendered as a card — airline(s), route, price,
/// score, duration/stops, and a Book deep-link. Shared by the standalone
/// FlightSearchScreen and the AI agent chat. Set [isBest] to highlight the top
/// pick with a teal border and "BEST MATCH" badge.
class FlightOfferCard extends StatelessWidget {
  final FlightOffer offer;
  final bool isBest;

  /// Green savings pill next to the BEST MATCH badge; the results list
  /// computes it via [savingsLabelFor] so the card stays presentational.
  final String? savingsLabel;
  const FlightOfferCard(
      {super.key, required this.offer, this.isBest = false, this.savingsLabel});

  /// Baggage badge under the price on baggage-aware searches; null otherwise.
  /// "paid" prices already fold the fee into [FlightOffer.displayPrice] — the
  /// badge explains where the number came from.
  String? _bagBadge(AppLocalizations l10n) => switch (offer.baggageStatus) {
        'included' => l10n.flightCardBagIncluded,
        'paid' =>
          l10n.flightCardBagPaid(formatMoney(offer.bagFee, offer.currency)),
        'unknown' => l10n.flightCardBagUnknown,
        _ => null,
      };

  Future<void> _book(BuildContext context) async {
    final url = offer.bookingUrl;
    if (url == null || url.isEmpty) return;
    final l10n = context.l10n;
    final ok = await trackedLaunchUrl(context, url,
        provider: 'duffel', surface: 'flight_card');
    if (!ok && context.mounted) {
      showSnack(context, l10n.flightCardOpenLinkError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final accent = AppColors.brand;

    return Card(
      // Elevation/shape come from cardTheme; only the best-match border is
      // bespoke.
      clipBehavior: Clip.antiAlias,
      shape: isBest
          ? RoundedRectangleBorder(
              borderRadius: AppRadius.mdAll,
              side: BorderSide(color: accent, width: 2),
            )
          : null,
      child: InkWell(
        onTap: () => showFlightDetails(context, offer),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isBest || savingsLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (isBest)
                        StatusPill.custom(
                          label: l10n.flightCardBestMatch,
                          background: accent,
                          foreground: Colors.white,
                        ),
                      if (savingsLabel case final label?)
                        // Deferred: swap for AppColors.successContainer/
                        // onSuccessContainer once the wave2-foundations
                        // tokens land (not in this branch's ancestry).
                        StatusPill.custom(
                          label: label,
                          background: Colors.green.withValues(alpha: 0.15),
                          foreground: Colors.green.shade800,
                        ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            AirlineLogo(url: offer.airlineLogoUrl, size: 22),
                            if (offer.airlineLogoUrl != null &&
                                offer.airlineLogoUrl!.isNotEmpty)
                              const SizedBox(width: AppSpacing.sm),
                            Flexible(
                              child: Text(
                                offer.airlines.isEmpty
                                    ? l10n.flightCardFlight
                                    : offer.airlines.join(', '),
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        if (offer.segments.isNotEmpty)
                          _SliceTimes(legs: offer.segments),
                        if (offer.isRoundTrip) ...[
                          const SizedBox(height: 2),
                          _SliceTimes(legs: offer.returnSegments),
                        ],
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatMoney(offer.displayPrice, offer.currency),
                        style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold, color: accent),
                      ),
                      if (_bagBadge(l10n) case final badge?)
                        Text(badge,
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: offer.bagFeeUnknown
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant)),
                      Text(l10n.flightCardScore(offer.score.toStringAsFixed(1)),
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  // Flexible + ellipsis on both stats: a round-trip duration
                  // next to a Spanish stops label overflows a 360px card
                  // otherwise. The inner Row (instead of a Spacer) keeps the
                  // Book button pinned right without stealing flex space.
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: _Stat(
                              icon: Icons.schedule,
                              label: offer.isRoundTrip
                                  ? '${offer.durationLabel} + ${offer.returnDurationLabel}'
                                  : offer.durationLabel),
                        ),
                        const SizedBox(width: AppSpacing.lg),
                        Flexible(
                          child: _Stat(
                              icon: Icons.connecting_airports,
                              label: combinedStopsLabel(l10n, offer)),
                        ),
                        if (offer.stops > 0 || offer.returnStops > 0) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Icon(Icons.chevron_right,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant),
                        ],
                      ],
                    ),
                  ),
                  if (offer.bookingUrl != null)
                    TextButton.icon(
                      onPressed: () => _book(context),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(l10n.flightCardBook),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Route line for one slice with departure/arrival clock times, e.g.
/// "EWR 10:50 → GIG 00:47 +1". Round-trip offers render one per direction
/// (the reversed airport codes make the direction self-evident).
class _SliceTimes extends StatelessWidget {
  final List<FlightLeg> legs;
  const _SliceTimes({required this.legs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final from = legs.first.from;
    final to = legs.last.to;
    final departClock = _clock(legs.first.departTime);
    final arriveClock = _clock(legs.last.arriveTime);
    final dayOffset = _dayOffset(legs.first.departTime, legs.last.arriveTime);
    final bold = theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600);
    final base = theme.textTheme.bodyMedium?.copyWith(color: muted);

    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: '$from '),
          if (departClock.isNotEmpty) TextSpan(text: departClock, style: bold),
          const TextSpan(text: '  →  '),
          TextSpan(text: '$to '),
          if (arriveClock.isNotEmpty) TextSpan(text: arriveClock, style: bold),
          if (dayOffset > 0)
            TextSpan(
              text: ' +$dayOffset',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }

  /// "hh:mm" for an ISO8601 time, empty if unparseable.
  static String _clock(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  /// Calendar days the arrival falls after the departure (for the "+N" badge).
  static int _dayOffset(String depart, String arrive) {
    final d = DateTime.tryParse(depart);
    final a = DateTime.tryParse(arrive);
    if (d == null || a == null) return 0;
    return DateTime(a.year, a.month, a.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Stat({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color)),
        ),
      ],
    );
  }
}
