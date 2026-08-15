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
import '../utils/snack.dart';

/// Left indent that aligns segment/layover detail rows under their leading
/// 18px icon (icon + the gap after it).
const double _kSegmentIndent = 18 + AppSpacing.sm;

/// Opens a modal bottom sheet with the segment-by-segment breakdown of [offer]:
/// each leg's carrier/flight number and depart→arrive clock times, plus the
/// connecting airport and layover duration between consecutive legs.
///
/// Layovers are computed from two timestamps at the *same* airport
/// (`segments[i].arriveTime` and `segments[i+1].departTime`), so they are
/// timezone-safe. We deliberately do not show a per-leg flight duration: the
/// ISO8601 segment times carry no offset and crossing timezones would be wrong —
/// total duration comes from the API via [FlightOffer.durationLabel].
Future<void> showFlightDetails(BuildContext context, FlightOffer offer) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Desktop width cap: a full-bleed 1440px segment list reads as a
    // handful of rows stranded across the window.
    constraints: const BoxConstraints(maxWidth: 700),
    builder: (context) => _FlightDetailsSheet(offer: offer),
  );
}

class _FlightDetailsSheet extends StatelessWidget {
  final FlightOffer offer;
  const _FlightDetailsSheet({required this.offer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final segments = offer.segments;
    final from = segments.isNotEmpty ? segments.first.from : '';
    final to = segments.isNotEmpty ? segments.last.to : '';

    // One-way: a flat segment list. Round-trip: an Outbound and a Return
    // section, each with its own duration/stops summary.
    final rows = <Widget>[];
    if (offer.isRoundTrip) {
      rows.add(_DirectionHeader(
          label: l10n.flightSheetOutbound,
          detail: '${offer.durationLabel} · ${stopsLabel(l10n, offer.stops)}'));
      rows.addAll(_sliceRows(offer.segments));
      rows.add(const Divider(height: AppSpacing.xl));
      rows.add(_DirectionHeader(
          label: l10n.flightSheetReturn,
          detail:
              '${offer.returnDurationLabel} · ${stopsLabel(l10n, offer.returnStops)}'));
      rows.addAll(_sliceRows(offer.returnSegments));
    } else {
      rows.addAll(_sliceRows(segments));
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AirlineLogo(url: offer.airlineLogoUrl, size: 28),
                  if (offer.airlineLogoUrl != null &&
                      offer.airlineLogoUrl!.isNotEmpty)
                    const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      offer.isRoundTrip ? '$from ⇄ $to' : '$from → $to',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  // The number the traveler is comparing shouldn't vanish at
                  // the moment they decide to book.
                  Text(
                    formatMoney(offer.displayPrice, offer.currency),
                    style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold, color: AppColors.brand),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                offer.isRoundTrip
                    ? l10n.flightSheetRoundTrip
                    : '${offer.durationLabel} · ${stopsLabel(l10n, offer.stops)}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Divider(height: AppSpacing.xl),
              _BaggageRow(offer: offer),
              const Divider(height: AppSpacing.xl),
              ...rows,
              if (offer.bookingUrl != null) ...[
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _book(context, offer.bookingUrl!),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(offer.airlines.isEmpty
                        ? l10n.flightSheetBookThisFlight
                        : l10n.flightSheetBookWith(offer.airlines.first)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Segment rows for one slice, with layover rows between consecutive legs.
List<Widget> _sliceRows(List<FlightLeg> segments) {
  final rows = <Widget>[];
  for (var i = 0; i < segments.length; i++) {
    rows.add(_SegmentRow(leg: segments[i]));
    if (i < segments.length - 1) {
      rows.add(_LayoverRow(
        airport: segments[i].to,
        duration: _layover(segments[i], segments[i + 1]),
      ));
    }
  }
  return rows;
}

/// Included-baggage allowance (worst case across all flown segments), plus
/// the added bag fee or unknown-fee warning on baggage-aware searches.
class _BaggageRow extends StatelessWidget {
  final FlightOffer offer;
  const _BaggageRow({required this.offer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;

    final included = <String>[
      l10n.flightSheetBagPersonalItem,
      if (offer.includedCarryOn > 0)
        l10n.flightSheetBagCarryOnCount(offer.includedCarryOn),
      if (offer.includedChecked > 0)
        l10n.flightSheetBagCheckedCount(offer.includedChecked),
    ];

    String? note;
    Color? noteColor;
    switch (offer.baggageStatus) {
      case 'paid':
        note = l10n
            .flightSheetBagFeeNote(formatMoney(offer.bagFee, offer.currency));
        noteColor = muted;
      case 'in_price':
        // The provider folded the fee into the quote without breaking it out,
        // so state the fact rather than inventing an amount.
        note = l10n.flightSheetBagInPriceNote;
        noteColor = muted;
      case 'unknown':
        note = l10n.flightSheetBagUnknownNote;
        noteColor = theme.colorScheme.error;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.luggage_outlined, size: 18, color: muted),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.flightSheetIncluded(included.join(' + ')),
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              if (note != null)
                Text(note,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: noteColor)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Section header for one direction of a round trip, e.g.
/// "Outbound · 7h 30m · Nonstop".
class _DirectionHeader extends StatelessWidget {
  final String label;
  final String detail;
  const _DirectionHeader({required this.label, required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Text(label,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// One flown leg: carrier + flight number, then "FROM hh:mm → TO hh:mm (+N)".
class _SegmentRow extends StatelessWidget {
  final FlightLeg leg;
  const _SegmentRow({required this.leg});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final bold = theme.textTheme.bodyLarge?.copyWith(
        color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600);
    final base = theme.textTheme.bodyLarge?.copyWith(color: muted);
    final dayOffset = _dayOffset(leg.departTime, leg.arriveTime);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.flight_takeoff,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _carrierLabel(context.l10n, leg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.only(left: _kSegmentIndent),
            child: Text.rich(
              TextSpan(
                style: base,
                children: [
                  TextSpan(text: '${leg.from} '),
                  TextSpan(text: _clock(leg.departTime), style: bold),
                  const TextSpan(text: '  →  '),
                  TextSpan(text: '${leg.to} '),
                  TextSpan(text: _clock(leg.arriveTime), style: bold),
                  if (dayOffset > 0)
                    TextSpan(
                      text: ' +$dayOffset',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Layover row between two legs, e.g. "Layover LIS · 1h 25m".
class _LayoverRow extends StatelessWidget {
  final String airport;
  final Duration? duration;
  const _LayoverRow({required this.airport, required this.duration});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = duration == null
        ? l10n.flightSheetLayover(airport)
        : l10n.flightSheetLayoverWithDuration(airport, _hm(duration!));
    return Padding(
      padding: const EdgeInsets.only(
          left: _kSegmentIndent, top: AppSpacing.xs, bottom: AppSpacing.xs),
      child: Row(
        children: [
          Icon(Icons.timelapse, size: 16, color: muted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: muted, fontStyle: FontStyle.italic)),
          ),
        ],
      ),
    );
  }
}

/// Opens the offer's booking link (airline site or airline-filtered Google
/// Flights) in an external tab.
Future<void> _book(BuildContext context, String url) async {
  final l10n = context.l10n;
  final ok = await trackedLaunchUrl(context, url,
      provider: 'duffel', surface: 'flight_details');
  if (!ok && context.mounted) showSnack(context, l10n.flightCardOpenLinkError);
}

/// "TAP TP204" — carrier name with flight number, de-duplicating when the
/// flight number already starts with the carrier text.
String _carrierLabel(AppLocalizations l10n, FlightLeg leg) {
  final carrier = leg.carrier.trim();
  final number = leg.flightNumber.trim();
  if (number.isEmpty) return carrier.isEmpty ? l10n.flightCardFlight : carrier;
  if (carrier.isEmpty) return number;
  return '$carrier $number';
}

/// "hh:mm" for an ISO8601 time, empty if unparseable.
String _clock(String iso) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Calendar days a leg's arrival falls after its departure (for the "+N" badge).
int _dayOffset(String depart, String arrive) {
  final d = DateTime.tryParse(depart);
  final a = DateTime.tryParse(arrive);
  if (d == null || a == null) return 0;
  return DateTime(a.year, a.month, a.day)
      .difference(DateTime(d.year, d.month, d.day))
      .inDays;
}

/// Layover between the arrival of [prev] and the departure of [next] — both at
/// the same airport, so the local-time subtraction is correct. Null if either
/// time is unparseable or the gap is negative.
Duration? _layover(FlightLeg prev, FlightLeg next) {
  final arrive = DateTime.tryParse(prev.arriveTime);
  final depart = DateTime.tryParse(next.departTime);
  if (arrive == null || depart == null) return null;
  final gap = depart.difference(arrive);
  return gap.isNegative ? null : gap;
}

/// "Xh Ym" duration label, matching FlightOffer.durationLabel's style.
String _hm(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}
