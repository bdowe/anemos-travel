import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/airport.dart';
import '../models/flight_search_request.dart';
import '../providers/auth_provider.dart';
import '../providers/flights_provider.dart';
import '../providers/preferences_provider.dart';
import '../utils/errors.dart';
import '../widgets/airport_field.dart';
import '../widgets/page_container.dart';
import '../widgets/create_alert_sheet.dart';
import '../widgets/flight_offer_card.dart';
import '../widgets/gradient_app_bar.dart';

// Canonical API values. These are sent to the Duffel-backed API, so they are
// NEVER translated — only their display labels are (specs/i18n-spanish).
const _cabinClasses = ['economy', 'premium_economy', 'business', 'first'];
const _presets = ['cost', 'time', 'balanced'];
const _baggageValues = ['personal_item', 'carry_on', 'checked'];

String _cabinLabel(AppLocalizations l10n, String value) => switch (value) {
      'economy' => l10n.flightSearchCabinEconomy,
      'premium_economy' => l10n.flightSearchCabinPremiumEconomy,
      'business' => l10n.flightSearchCabinBusiness,
      'first' => l10n.flightSearchCabinFirst,
      _ => value,
    };

String _presetLabel(AppLocalizations l10n, String value) => switch (value) {
      'cost' => l10n.flightSearchPresetCheapest,
      'time' => l10n.flightSearchPresetFastest,
      'balanced' => l10n.flightSearchPresetBalanced,
      _ => value,
    };

String _baggageLabel(AppLocalizations l10n, String value) => switch (value) {
      'personal_item' => l10n.flightSearchBaggagePersonalItem,
      'carry_on' => l10n.flightSearchBaggageCarryOn,
      'checked' => l10n.flightSearchBaggageChecked,
      _ => value,
    };

/// Standalone flight search: pick origin/destination/date/passengers and a
/// ranking preset, then browse offers ranked by the Duffel-backed API.
///
/// Optional prefill ([prefillOrigin]/[prefillDestination] may be an IATA code or
/// a city name; [prefillDepartDate] is YYYY-MM-DD) lets callers (e.g. a trip's
/// flight booking item) open the screen ready to search. Prefill takes
/// precedence over the saved home-airport origin seed.
class FlightSearchScreen extends ConsumerStatefulWidget {
  final String? prefillOrigin;
  final String? prefillDestination;
  final String? prefillDepartDate;

  /// Optional coordinates for the prefilled origin/destination. When the name
  /// has no IATA match (e.g. a village like Imerovigli), these resolve to the
  /// nearest bookable airport (e.g. Santorini/JTR).
  final ({double lat, double lng})? prefillOriginCoord;
  final ({double lat, double lng})? prefillDestinationCoord;

  const FlightSearchScreen({
    super.key,
    this.prefillOrigin,
    this.prefillDestination,
    this.prefillDepartDate,
    this.prefillOriginCoord,
    this.prefillDestinationCoord,
  });

  @override
  ConsumerState<FlightSearchScreen> createState() => _FlightSearchScreenState();
}

class _FlightSearchScreenState extends ConsumerState<FlightSearchScreen> {
  Airport? _origin;
  Airport? _destination;
  DateTime? _departDate;

  /// Optional round-trip return date; null = one-way (the default).
  DateTime? _returnDate;
  int _adults = 1;

  /// One entry per child passenger; the value is the child's age (0–17).
  /// Duffel prices children by real age, so each child gets its own picker.
  final List<int> _childAges = [];
  String _cabinClass = 'economy';

  /// The parameters of the last submitted search (see _search); the alert
  /// entry point reads these so an edited-but-unsearched form can't mislabel
  /// a watch.
  ({
    String origin,
    String destination,
    String departDate,
    String? returnDate,
    int adults,
    String cabinClass,
    String baggage,
    bool hasChildren,
  })? _watched;

  /// Age a newly added child starts at before the traveler adjusts it.
  static const _defaultChildAge = 8;
  String _optimizeFor = 'balanced';

  /// Biggest bag needed. Beyond personal_item, results are ranked by the
  /// effective total (fare + bag fee when the bag isn't included).
  String _baggage = 'personal_item';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedInitial());
  }

  /// Seeds the form from explicit prefill (origin/destination/date) when given,
  /// otherwise falls back to the saved home airport for the origin. Both are
  /// still editable.
  Future<void> _seedInitial() async {
    final w = widget;
    var date = w.prefillDepartDate == null
        ? null
        : DateTime.tryParse(w.prefillDepartDate!);
    if (date != null) {
      // Prefill dates come from itinerary legs, which are unbounded (past
      // trips, trips >1 year out). Clamp into the pickers' bookable window
      // [today, today+365d] so neither date picker can be handed an
      // out-of-range initial/first date (showDatePicker asserts on those).
      final today = DateUtils.dateOnly(DateTime.now());
      final windowEnd = today.add(const Duration(days: 365));
      if (date.isBefore(today)) date = today;
      if (date.isAfter(windowEnd)) date = windowEnd;
    }
    if (date != null && _departDate == null) {
      setState(() => _departDate = date);
    }

    // Resolve origin and destination concurrently so a slow/failed lookup on one
    // side doesn't delay or blank the other. Each result is applied on its own.
    final originFuture =
        (w.prefillOrigin != null && w.prefillOrigin!.isNotEmpty)
            ? _resolve(w.prefillOrigin!, coord: w.prefillOriginCoord)
            : _homeAirportSeed();
    final destFuture =
        (w.prefillDestination != null && w.prefillDestination!.isNotEmpty)
            ? _resolve(w.prefillDestination!, coord: w.prefillDestinationCoord)
            : Future<Airport?>.value(null);

    final resolved = await Future.wait([originFuture, destFuture]);
    final origin = resolved[0];
    final dest = resolved[1];
    if (origin != null && _origin == null && mounted) {
      setState(() => _origin = origin);
    }
    if (dest != null && _destination == null && mounted) {
      setState(() => _destination = dest);
    }

    // Run the search as soon as it's runnable (both endpoints resolved + a date),
    // regardless of which inputs were prefilled vs. seeded — so the caller lands
    // on results without tapping Search.
    if (mounted && _canSearch) _search();
  }

  /// Falls back to the traveler's saved home airport when no explicit origin was
  /// prefilled. Returns null when none is set.
  Future<Airport?> _homeAirportSeed() async {
    await ref.read(preferencesProvider.notifier).load();
    final code = ref.read(preferencesProvider).prefs?.homeAirport;
    if (code == null || code.isEmpty) return null;
    return Airport(iataCode: code, name: code);
  }

  /// Resolves an IATA code or city name to an [Airport]. A 3-letter alphabetic
  /// input is used as-is; otherwise the Duffel airport search resolves it. When
  /// the raw label finds nothing (e.g. a label with a postal/qualifier prefix),
  /// it retries once with a cleaned query, then — if [coord] is given — falls
  /// back to the nearest airport by coordinate (e.g. a village -> its island
  /// airport). Mirrors the backend's resolveIATA.
  Future<Airport?> _resolve(String query,
      {({double lat, double lng})? coord}) async {
    final q = query.trim();
    final isCode = q.length == 3 && RegExp(r'^[A-Za-z]{3}$').hasMatch(q);
    if (isCode)
      return Airport(iataCode: q.toUpperCase(), name: q.toUpperCase());

    final cleaned = _cleanLabel(q);
    final attempts = <String>[q, if (cleaned != q) cleaned];
    for (final attempt in attempts) {
      final hit = await _lookupAirport(attempt);
      if (hit != null) return hit;
    }
    if (coord != null) return _nearestAirport(coord.lat, coord.lng);
    return null;
  }

  /// Looks up the nearest bookable airport to a coordinate. Returns null on
  /// empty results or any error.
  Future<Airport?> _nearestAirport(double lat, double lng) async {
    try {
      final results =
          await ref.read(flightsApiServiceProvider).nearestAirports(lat, lng);
      return results.isEmpty ? null : results.first;
    } catch (_) {
      return null;
    }
  }

  /// Runs one airport lookup, preferring an `airport`-type result over a `city`
  /// (so we book against a concrete airport when the typeahead returns both).
  /// Returns null on empty results or any error so the caller can retry/fall back.
  Future<Airport?> _lookupAirport(String query) async {
    try {
      final results =
          await ref.read(flightsApiServiceProvider).searchAirports(query);
      if (results.isEmpty) return null;
      return results.firstWhere(
        (a) => a.subType.toLowerCase() == 'airport',
        orElse: () => results.first,
      );
    } catch (_) {
      return null;
    }
  }

  /// Drops any trailing qualifier after a comma and collapses a leading
  /// postal/qualifier token, e.g. "1400 Lisboa, Portugal" -> "Lisboa".
  String _cleanLabel(String label) {
    var s = label.split(',').first.trim();
    final tokens = s.split(RegExp(r'\s+'));
    if (tokens.length > 1 && RegExp(r'\d').hasMatch(tokens.first)) {
      s = tokens.sublist(1).join(' ').trim();
    }
    return s.isEmpty ? label : s;
  }

  bool get _canSearch =>
      _origin != null && _destination != null && _departDate != null;

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final first = now;
    final last = now.add(const Duration(days: 365));
    // Defensive initial clamp: _departDate is clamped at seed time, but keep
    // the picker safe against any out-of-window value regardless of source.
    var initial = _departDate ?? now.add(const Duration(days: 14));
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) {
      setState(() {
        _departDate = picked;
        // A return before the new departure is impossible; clear it rather
        // than silently guessing a new one.
        if (_returnDate != null && _returnDate!.isBefore(picked)) {
          _returnDate = null;
        }
      });
    }
  }

  /// Picks the optional return date. The picker's floor is the departure date,
  /// so return < departure is impossible to select (same-day return allowed).
  Future<void> _pickReturnDate() async {
    final now = DateTime.now();
    // Reconcile the range before handing it to the picker: a stale or
    // prefilled departure can sit outside [today, today+365d], and
    // showDatePicker asserts when firstDate > lastDate. Floor the start at
    // today (no past returns), then extend the end if the departure still
    // overruns it.
    var first = _departDate ?? now;
    if (first.isBefore(now)) first = now;
    var last = now.add(const Duration(days: 365));
    if (last.isBefore(first)) last = first;
    var initial = _returnDate ??
        _departDate?.add(const Duration(days: 7)) ??
        now.add(const Duration(days: 21));
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) setState(() => _returnDate = picked);
  }

  void _search() {
    if (!_canSearch) return;
    // Snapshot what was actually searched: the "Watch this route" alert must
    // describe these parameters, not whatever the form says later.
    final returnDate = _returnDate == null ? null : _fmtDate(_returnDate!);
    _watched = (
      origin: _origin!.iataCode,
      destination: _destination!.iataCode,
      departDate: _fmtDate(_departDate!),
      returnDate: returnDate,
      adults: _adults,
      cabinClass: _cabinClass,
      baggage: _baggage,
      hasChildren: _childAges.isNotEmpty,
    );
    ref.read(flightsProvider.notifier).search(FlightSearchRequest(
          origin: _origin!.iataCode,
          destination: _destination!.iataCode,
          departDate: _fmtDate(_departDate!),
          returnDate: returnDate,
          adults: _adults,
          childAges: _childAges.isEmpty ? null : List.of(_childAges),
          cabinClass: _cabinClass == 'economy' ? null : _cabinClass,
          baggage: _baggage == 'personal_item' ? null : _baggage,
          optimizeFor: _optimizeFor,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(flightsProvider);
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      appBar: GradientAppBar(title: Text(l10n.flightSearchTitle)),
      body: Column(
        children: [
          // Search form: the surface color stays full-bleed; the fields
          // cap to the shared 700px column (declutter series).
          Container(
            color: theme.colorScheme.surface,
            padding: const EdgeInsets.all(16),
            child: PageContainer(
              child: Column(
                children: [
                  AirportField(
                    label: l10n.flightSearchFrom,
                    icon: Icons.flight_takeoff,
                    selected: _origin,
                    onSelected: (a) => setState(() => _origin = a),
                  ),
                  const SizedBox(height: 12),
                  AirportField(
                    label: l10n.flightSearchTo,
                    icon: Icons.flight_land,
                    selected: _destination,
                    onSelected: (a) => setState(() => _destination = a),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickDate,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(_departDate == null
                              ? l10n.flightSearchDepartDate
                              : _fmtDate(_departDate!)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickReturnDate,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(_returnDate == null
                              ? l10n.flightSearchReturnOptional
                              : _fmtDate(_returnDate!)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      if (_returnDate != null)
                        IconButton(
                          tooltip: l10n.flightSearchClearReturnTooltip,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _returnDate = null),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _PassengerStepper(
                        icon: Icons.person_outline,
                        count: _adults,
                        min: 1,
                        onChanged: (v) => setState(() => _adults = v),
                      ),
                      const SizedBox(width: 8),
                      _PassengerStepper(
                        icon: Icons.child_care_outlined,
                        count: _childAges.length,
                        min: 0,
                        onChanged: (v) => setState(() {
                          while (_childAges.length < v) {
                            _childAges.add(_defaultChildAge);
                          }
                          while (_childAges.length > v) {
                            _childAges.removeLast();
                          }
                        }),
                      ),
                    ],
                  ),
                  if (_childAges.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(l10n.flightSearchChildAges,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                          for (var i = 0; i < _childAges.length; i++)
                            DropdownButton<int>(
                              value: _childAges[i],
                              isDense: true,
                              items: [
                                for (var age = 0; age <= 17; age++)
                                  DropdownMenuItem(
                                    value: age,
                                    child: Text('$age'),
                                  ),
                              ],
                              onChanged: (age) {
                                if (age != null) {
                                  setState(() => _childAges[i] = age);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final value in _cabinClasses)
                          ChoiceChip(
                            label: Text(_cabinLabel(l10n, value)),
                            selected: _cabinClass == value,
                            onSelected: (_) =>
                                setState(() => _cabinClass = value),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: _baggageValues
                        .map((value) => ButtonSegment(
                              value: value,
                              label: Text(_baggageLabel(l10n, value)),
                            ))
                        .toList(),
                    selected: {_baggage},
                    onSelectionChanged: (s) =>
                        setState(() => _baggage = s.first),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: _presets
                        .map((value) => ButtonSegment(
                              value: value,
                              label: Text(_presetLabel(l10n, value)),
                            ))
                        .toList(),
                    selected: {_optimizeFor},
                    onSelectionChanged: (s) =>
                        setState(() => _optimizeFor = s.first),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _canSearch && !state.loading ? _search : null,
                      icon: state.loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search),
                      label: Text(state.loading
                          ? l10n.flightSearchSearching
                          : l10n.flightSearchSubmit),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // Watch-this-route entry (specs/price-alerts): only over a real
          // result set and only signed in — alerts need an email to notify.
          // Uses the searched snapshot, never the live form (which may have
          // been edited since), and skips the price baseline when children
          // were in the search (the checker re-searches adults only, so a
          // family-priced baseline would read as a fake drop).
          if (state.hasSearched &&
              state.offers.isNotEmpty &&
              _watched != null &&
              ref.watch(authProvider.select((s) => s.isSignedIn)))
            PageContainer(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton.icon(
                    icon: const Icon(Icons.notifications_none, size: 18),
                    label: Text(l10n.flightSearchWatchRoute),
                    onPressed: () {
                      final w = _watched!;
                      // Seed the baseline from the cheapest EFFECTIVE price —
                      // the checker tracks fare + bag fee on baggage-aware
                      // watches, so a bare-fare baseline would read as a drop.
                      // Unknown-fee offers can't seed a comparable baseline.
                      final priced =
                          state.offers.where((o) => !o.bagFeeUnknown).toList();
                      final cheapest = priced.isEmpty
                          ? null
                          : priced.reduce((a, b) =>
                              a.displayPrice <= b.displayPrice ? a : b);
                      final seedPrice = w.hasChildren ? null : cheapest;
                      CreateAlertSheet.show(
                        context,
                        CreateAlertSheet(
                          origin: w.origin,
                          destination: w.destination,
                          departDate: w.departDate,
                          returnDate: w.returnDate,
                          adults: w.adults,
                          cabinClass: w.cabinClass,
                          baggage: w.baggage,
                          currentPrice: seedPrice?.displayPrice,
                          currency: seedPrice?.currency,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          // Results (whole-scrollable cap, alerts/guides pattern)
          Expanded(child: PageContainer(child: _Results(state: state))),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  final FlightsState state;
  const _Results({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(l10n.flightSearchErrorTitle,
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                friendlyError(l10n, state.error),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    if (!state.hasSearched) {
      return _Hint(
        icon: Icons.flight,
        text: l10n.flightSearchHintInitial,
      );
    }

    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.offers.isEmpty) {
      return _Hint(
        icon: Icons.search_off,
        text: l10n.flightSearchHintEmpty,
      );
    }

    final savingsLabel = savingsLabelFor(l10n, state.offers, state.bestOfferId);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: state.offers.length,
      itemBuilder: (context, i) {
        final offer = state.offers[i];
        final isBest = offer.id == state.bestOfferId;
        return FlightOfferCard(
          offer: offer,
          isBest: isBest,
          savingsLabel: isBest ? savingsLabel : null,
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: color),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

class _PassengerStepper extends StatelessWidget {
  final IconData icon;
  final int count;
  final int min;
  final ValueChanged<int> onChanged;
  const _PassengerStepper({
    required this.icon,
    required this.count,
    required this.min,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(icon, size: 16),
          ),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: count > min ? () => onChanged(count - 1) : null,
            visualDensity: VisualDensity.compact,
          ),
          Text('$count', style: const TextStyle(fontWeight: FontWeight.bold)),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: count < 8 ? () => onChanged(count + 1) : null,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
