import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/airport.dart';
import '../theme/spacing.dart';
import 'airport_field.dart';

/// What the traveler asked this trip's airports to become. Both fields null
/// means "clear them" — fall back to the stated origin, then the saved home
/// airport. Popping null means they cancelled.
///
/// Never one set and one null: the two are stored together or not at all
/// (CHECK trips_endpoint_airport_pair), and the server refuses a one-sided
/// body, so the sheet cannot produce one either.
class TripAirportsChoice {
  final String? originAirport;
  final String? returnAirport;

  const TripAirportsChoice({this.originAirport, this.returnAirport});

  bool get isClear => originAirport == null && returnAirport == null;
}

/// Bottom sheet for the two airports THIS trip flies out of and home into
/// (specs/trip-endpoint-airports). Pops a [TripAirportsChoice] or null.
///
/// Not the traveler's saved home airport — that is a standing fact about them,
/// lives in Settings, and is only the last rung of the ladder these override.
class TripAirportsSheet extends StatefulWidget {
  /// The trip's own airports, or null when it states none.
  final String? originAirport;
  final String? returnAirport;

  /// What the legs read today when the trip states no airport: the origin the
  /// traveler stated in words, else their saved home airport. Shown as context,
  /// never as a value — seeding the fields with it would turn "open the sheet
  /// and press Save" into silently promoting a fallback to a fixed choice.
  final String? fallbackLabel;

  const TripAirportsSheet({
    super.key,
    this.originAirport,
    this.returnAirport,
    this.fallbackLabel,
  });

  @override
  State<TripAirportsSheet> createState() => _TripAirportsSheetState();
}

class _TripAirportsSheetState extends State<TripAirportsSheet> {
  /// The authoritative picks. [AirportField] voids these the moment the text is
  /// typed over, so "text present, selection null" is an unresolved edit — not
  /// "no airport", and saving it as one is how an edit gets thrown away under a
  /// success message.
  Airport? _departure;
  Airport? _arrival;
  String _departureQuery = '';
  String _arrivalQuery = '';
  bool _sameBothWays = true;
  String? _departureError;
  String? _arrivalError;

  @override
  void initState() {
    super.initState();
    final dep = widget.originAirport?.trim();
    final arr = widget.returnAirport?.trim();
    // A bare code is all the trip stores; the field renders its label, which
    // falls back to the code when no place name is known.
    if (dep != null && dep.isNotEmpty) {
      _departure = Airport(iataCode: dep, name: dep);
      _departureQuery = _departure!.label;
    }
    if (arr != null && arr.isNotEmpty) {
      _arrival = Airport(iataCode: arr, name: arr);
      _arrivalQuery = _arrival!.label;
    }
    _sameBothWays = dep == null || arr == null || dep == arr;
  }

  bool get _hasStoredAirports =>
      (widget.originAirport?.trim().isNotEmpty ?? false);

  void _save() {
    final depTyped = _departureQuery.trim().isNotEmpty;
    final arrTyped = _arrivalQuery.trim().isNotEmpty;
    final l10n = context.l10n;

    // An unresolved edit is refused rather than dropped.
    setState(() {
      _departureError =
          depTyped && _departure == null ? l10n.tripAirportsPickOne : null;
      _arrivalError = !_sameBothWays && arrTyped && _arrival == null
          ? l10n.tripAirportsPickOne
          : null;
    });
    if (_departureError != null || _arrivalError != null) return;

    if (_departure == null && (_sameBothWays || _arrival == null)) {
      Navigator.of(context).pop(const TripAirportsChoice());
      return;
    }
    // Half-stated is refused at the field that is missing, because the two ends
    // are stored together: accepting it would either invent the other end or
    // silently drop this one.
    if (_departure == null) {
      setState(() => _departureError = l10n.tripAirportsBothNeeded);
      return;
    }
    if (!_sameBothWays && _arrival == null) {
      setState(() => _arrivalError = l10n.tripAirportsBothNeeded);
      return;
    }
    Navigator.of(context).pop(TripAirportsChoice(
      originAirport: _departure!.iataCode,
      returnAirport:
          _sameBothWays ? _departure!.iataCode : _arrival!.iataCode,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final fallback = widget.fallbackLabel?.trim();
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.tripAirportsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              l10n.tripAirportsHelp,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.md),
            AirportField(
              label: l10n.tripAirportsDepartsFrom,
              icon: Icons.flight_takeoff,
              selected: _departure,
              errorText: _departureError,
              onSelected: (a) => setState(() {
                _departure = a;
                if (a != null) _departureError = null;
              }),
              onQueryChanged: (q) => _departureQuery = q,
            ),
            const SizedBox(height: AppSpacing.sm),
            CheckboxListTile(
              value: _sameBothWays,
              onChanged: (v) => setState(() {
                _sameBothWays = v ?? false;
                if (_sameBothWays) _arrivalError = null;
              }),
              title: Text(l10n.tripAirportsSameBothWays),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            if (!_sameBothWays) ...[
              const SizedBox(height: AppSpacing.sm),
              AirportField(
                label: l10n.tripAirportsReturnsInto,
                icon: Icons.flight_land,
                selected: _arrival,
                errorText: _arrivalError,
                onSelected: (a) => setState(() {
                  _arrival = a;
                  if (a != null) _arrivalError = null;
                }),
                onQueryChanged: (q) => _arrivalQuery = q,
              ),
            ],
            if (!_hasStoredAirports && fallback != null && fallback.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.tripAirportsCurrentFallback(fallback),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                if (_hasStoredAirports)
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pop(const TripAirportsChoice()),
                    child: Text(l10n.tripAirportsUseHomeAirport),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _save,
                  child: Text(l10n.commonSave),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
