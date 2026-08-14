import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/airport.dart';
import '../models/flight_search_request.dart';
import '../providers/flights_provider.dart';
import '../providers/preferences_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/flight_labels.dart';
import '../widgets/airport_field.dart';
import '../widgets/choice_chip_row.dart';
import '../widgets/collapsible_section.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_container.dart';
import '../widgets/flight_offer_card.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/section_header.dart';

// Canonical API values. These are sent to the Duffel-backed API, so they are
// NEVER translated — only their display labels are (specs/i18n-spanish).
const _cabinClasses = ['economy', 'premium_economy', 'business', 'first'];
const _presets = ['cost', 'time', 'balanced'];
const _baggageValues = ['personal_item', 'carry_on', 'checked'];

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

  /// Whether the traveler has touched each endpoint. `_origin == null` is NOT a
  /// stand-in for "untouched": typing in an [AirportField] voids the held
  /// selection, so a slow seed (`_seedInitial` awaits the profile load and up to
  /// three lookups) would otherwise land on a field the user is typing in and
  /// overwrite it.
  bool _originTouched = false;
  bool _destinationTouched = false;
  DateTime? _departDate;

  /// Optional round-trip return date; null = one-way (the default).
  DateTime? _returnDate;
  int _adults = 1;

  /// One entry per child passenger; the value is the child's age (0–17).
  /// Duffel prices children by real age, so each child gets its own picker.
  final List<int> _childAges = [];
  String _cabinClass = 'economy';

  /// Whether the search form is open. Parent-owned (CollapsibleSection house
  /// rule): a successful search collapses it to a one-line summary so results
  /// own the viewport on phones; tapping the row re-opens it to edit.
  bool _formExpanded = true;

  /// The parameters of the last submitted search (see _search); the
  /// collapsed-form summary reads these so an edited-but-unsearched form
  /// can't mislabel it.
  ({
    String origin,
    String destination,
    String departDate,
    String? returnDate,
    int adults,
    String cabinClass,
    String baggage,
    int children,
  })? _watched;

  /// The exact request last handed to the provider, so the error state's
  /// Retry re-runs what actually failed rather than the live form.
  FlightSearchRequest? _lastRequest;

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
    if (origin != null && _origin == null && !_originTouched && mounted) {
      setState(() => _origin = origin);
    }
    if (dest != null &&
        _destination == null &&
        !_destinationTouched &&
        mounted) {
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
    if (isCode) {
      return Airport(iataCode: q.toUpperCase(), name: q.toUpperCase());
    }

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

  /// Machine-facing YYYY-MM-DD for the API payload. User-facing labels go
  /// through [flightDateLabel] (localized DateFormat) instead.
  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Localized short display date for a picked [DateTime], e.g. "Sep 1" /
  /// "1 sept".
  String _displayDate(AppLocalizations l10n, DateTime d) =>
      flightDateLabel(l10n, _fmtDate(d));

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
    // Snapshot what was actually searched: the collapsed-form summary must
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
      children: _childAges.length,
    );
    final request = FlightSearchRequest(
      origin: _origin!.iataCode,
      destination: _destination!.iataCode,
      departDate: _fmtDate(_departDate!),
      returnDate: returnDate,
      adults: _adults,
      childAges: _childAges.isEmpty ? null : List.of(_childAges),
      cabinClass: _cabinClass == 'economy' ? null : _cabinClass,
      baggage: _baggage == 'personal_item' ? null : _baggage,
      optimizeFor: _optimizeFor,
    );
    _lastRequest = request;
    ref.read(flightsProvider.notifier).search(request);
  }

  /// Re-runs the last submitted request (error-state Retry). Falls back to a
  /// fresh submit if somehow none was recorded.
  void _retry() {
    final request = _lastRequest;
    if (request != null) {
      ref.read(flightsProvider.notifier).search(request);
    } else {
      _search();
    }
  }

  /// One-line summary of the last search for the collapsed form row, e.g.
  /// "JFK → CDG · Sep 1 – Sep 10 · 2 travelers · Business".
  String? _searchSummary(AppLocalizations l10n) {
    final w = _watched;
    if (w == null) return null;
    final dates = w.returnDate == null
        ? flightDateLabel(l10n, w.departDate)
        : '${flightDateLabel(l10n, w.departDate)} – ${flightDateLabel(l10n, w.returnDate!)}';
    final travelers = l10n.flightSearchSummaryTravelers(w.adults + w.children);
    final cabin = cabinClassLabel(l10n, w.cabinClass);
    return '${w.origin} → ${w.destination} · $dates · $travelers · $cabin';
  }

  @override
  Widget build(BuildContext context) {
    // Auto-collapse the form on the loading -> loaded edge of a SUCCESSFUL
    // search so the results own the viewport; a failed search keeps the form
    // open for fixing inputs.
    ref.listen<FlightsState>(flightsProvider, (prev, next) {
      final wasLoading = prev?.loading ?? false;
      if (wasLoading &&
          !next.loading &&
          next.error == null &&
          next.hasSearched &&
          _formExpanded) {
        setState(() => _formExpanded = false);
      }
    });

    final state = ref.watch(flightsProvider);
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      appBar: GradientAppBar(title: Text(l10n.flightSearchTitle)),
      // One scroll surface for form + results (declutter series): the form
      // can't push results off a phone viewport, and the whole page scrolls.
      body: CustomScrollView(
        slivers: [
          // Search form: the surface color stays full-bleed; the fields cap
          // to the shared 700px column (PageContainer INSIDE the scrollable).
          SliverToBoxAdapter(
            child: Container(
              color: theme.colorScheme.surface,
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: PageContainer(
                child: CollapsibleSection(
                  icon: Icons.search,
                  title: _formExpanded
                      ? l10n.flightSearchFormTitle
                      : l10n.flightSearchEditSearch,
                  summary: _formExpanded ? null : _searchSummary(l10n),
                  expanded: _formExpanded,
                  onToggle: () =>
                      setState(() => _formExpanded = !_formExpanded),
                  child: _buildForm(context, state, l10n, theme),
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          ..._resultSlivers(state, l10n, theme),
        ],
      ),
    );
  }

  /// The expanded search form. Built only while [_formExpanded]
  /// (CollapsibleSection contract); all values live on this State, so
  /// collapse/expand loses nothing.
  Widget _buildForm(BuildContext context, FlightsState state,
      AppLocalizations l10n, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AirportField(
          label: l10n.flightSearchFrom,
          icon: Icons.flight_takeoff,
          selected: _origin,
          onSelected: (a) => setState(() {
            _origin = a;
            _originTouched = true;
          }),
        ),
        const SizedBox(height: AppSpacing.md),
        AirportField(
          label: l10n.flightSearchTo,
          icon: Icons.flight_land,
          selected: _destination,
          onSelected: (a) => setState(() {
            _destination = a;
            _destinationTouched = true;
          }),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(
                  _departDate == null
                      ? l10n.flightSearchDepartDate
                      : _displayDate(l10n, _departDate!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickReturnDate,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(
                  _returnDate == null
                      ? l10n.flightSearchReturnOptional
                      : _displayDate(l10n, _returnDate!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
        const SizedBox(height: AppSpacing.md),
        // Wrap, not Row: the labeled steppers don't fit side by side at
        // 360px (especially in Spanish), so they stack instead of clipping.
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _PassengerStepper(
              icon: Icons.person_outline,
              label: l10n.flightSearchAdults,
              addTooltip: l10n.flightSearchAddAdult,
              removeTooltip: l10n.flightSearchRemoveAdult,
              count: _adults,
              min: 1,
              onChanged: (v) => setState(() => _adults = v),
            ),
            _PassengerStepper(
              icon: Icons.child_care_outlined,
              label: l10n.flightSearchChildren,
              addTooltip: l10n.flightSearchAddChild,
              removeTooltip: l10n.flightSearchRemoveChild,
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
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.sm,
            children: [
              for (var i = 0; i < _childAges.length; i++)
                SizedBox(
                  width: 132,
                  child: DropdownButtonFormField<int>(
                    initialValue: _childAges[i],
                    decoration: InputDecoration(
                      labelText: l10n.flightSearchChildN(i + 1),
                    ),
                    items: [
                      for (var age = 0; age <= 17; age++)
                        DropdownMenuItem(value: age, child: Text('$age')),
                    ],
                    onChanged: (age) {
                      if (age != null) {
                        setState(() => _childAges[i] = age);
                      }
                    },
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        SectionHeader(title: l10n.flightSearchCabinLabel),
        const SizedBox(height: AppSpacing.sm),
        // Single-select with a value at all times: re-tapping the selected
        // chip reports null (ChoiceChipRow's deselect), which we ignore.
        ChoiceChipRow(
          options: _cabinClasses,
          selected: _cabinClass,
          labelBuilder: (v) => cabinClassLabel(l10n, v),
          onSelected: (v) => setState(() => _cabinClass = v ?? _cabinClass),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionHeader(title: l10n.flightSearchBaggageLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipRow(
          options: _baggageValues,
          selected: _baggage,
          labelBuilder: (v) => _baggageLabel(l10n, v),
          onSelected: (v) => setState(() => _baggage = v ?? _baggage),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionHeader(title: l10n.flightSearchOptimizeLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipRow(
          options: _presets,
          selected: _optimizeFor,
          labelBuilder: (v) => _presetLabel(l10n, v),
          onSelected: (v) => setState(() => _optimizeFor = v ?? _optimizeFor),
        ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _canSearch && !state.loading ? _search : null,
            icon: state.loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: theme.colorScheme.onPrimary),
                  )
                : const Icon(Icons.search),
            label: Text(state.loading
                ? l10n.flightSearchSearching
                : l10n.flightSearchSubmit),
          ),
        ),
      ],
    );
  }

  /// Results region of the scroll view. Hint/empty/error states fill the
  /// leftover viewport (SliverFillRemaining) so they center like every other
  /// EmptyState screen; real results are a lazy SliverList with each row
  /// capped by PageContainer (gutters stay wheel/scrollbar-live).
  List<Widget> _resultSlivers(
      FlightsState state, AppLocalizations l10n, ThemeData theme) {
    if (state.error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.cloud_off,
            title: l10n.flightSearchErrorTitle,
            message: friendlyError(l10n, state.error),
            iconColor: theme.colorScheme.error.withValues(alpha: 0.6),
            actions: [
              FilledButton(
                onPressed: _retry,
                child: Text(l10n.commonRetry),
              ),
            ],
          ),
        ),
      ];
    }

    if (!state.hasSearched) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.flight,
            title: l10n.flightSearchHintInitialTitle,
            message: l10n.flightSearchHintInitial,
          ),
        ),
      ];
    }

    if (state.loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (state.offers.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.search_off,
            title: l10n.flightSearchNoResultsTitle,
            message: l10n.flightSearchHintEmpty,
          ),
        ),
      ];
    }

    final savingsLabel = savingsLabelFor(l10n, state.offers, state.bestOfferId);
    return [
      SliverPadding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i == 0) {
                return PageContainer(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: SectionHeader(
                      title: l10n.flightSearchResultsCount(state.offers.length),
                      action: Text(
                        _presetLabel(l10n, state.optimizeFor),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                );
              }
              final offer = state.offers[i - 1];
              final isBest = offer.id == state.bestOfferId;
              return PageContainer(
                child: FlightOfferCard(
                  offer: offer,
                  isBest: isBest,
                  savingsLabel: isBest ? savingsLabel : null,
                ),
              );
            },
            childCount: state.offers.length + 1,
          ),
        ),
      ),
    ];
  }
}

class _PassengerStepper extends StatelessWidget {
  final IconData icon;
  final String label;
  final String addTooltip;
  final String removeTooltip;
  final int count;
  final int min;
  final ValueChanged<int> onChanged;
  const _PassengerStepper({
    required this.icon,
    required this.label,
    required this.addTooltip,
    required this.removeTooltip,
    required this.count,
    required this.min,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: label,
      value: '$count',
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: AppRadius.smAll,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: Icon(icon,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            IconButton(
              tooltip: removeTooltip,
              icon: const Icon(Icons.remove, size: 18),
              onPressed: count > min ? () => onChanged(count - 1) : null,
            ),
            Text('$count', style: const TextStyle(fontWeight: FontWeight.bold)),
            IconButton(
              tooltip: addTooltip,
              icon: const Icon(Icons.add, size: 18),
              onPressed: count < 8 ? () => onChanged(count + 1) : null,
            ),
          ],
        ),
      ),
    );
  }
}
