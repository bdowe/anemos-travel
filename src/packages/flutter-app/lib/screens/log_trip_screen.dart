import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../models/place_search_result.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/log_trip_provider.dart';
import '../providers/places_api_provider.dart';
import '../theme/spacing.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';
import 'trip_detail_screen.dart';

/// One destination on the form. [lat]/[lng] are null together when the
/// traveler typed the name instead of picking a searched place — the pair is
/// never half-set, because half a coordinate is no coordinate. A location-less
/// destination still counts as a city in "Your travels"; it just never gets a
/// map pin, which the chip says out loud before the trip is saved.
class LogTripDestination {
  final String name;
  final String? placeId;
  final String? address;
  final double? lat;
  final double? lng;

  const LogTripDestination({
    required this.name,
    this.placeId,
    this.address,
    this.lat,
    this.lng,
  });

  LogTripDestination.fromPlace(PlaceSearchResult p)
      : name = p.name,
        placeId = p.placeId,
        address = p.address.isEmpty ? null : p.address,
        lat = p.latitude,
        lng = p.longitude;

  bool get isLocated => lat != null && lng != null;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (placeId != null) 'place_id': placeId,
        if (address != null) 'address': address,
        if (lat != null) 'latitude': lat,
        if (lng != null) 'longitude': lng,
      };
}

/// Handles for the form's two gating inputs, so tests can assert on the
/// widgets rather than on their localized labels.
const kLogTripSearchFieldKey = ValueKey('logTrip.search');
const kLogTripSaveButtonKey = ValueKey('logTrip.save');

/// Record a trip that already happened (specs/log-past-trip): destinations, the
/// dates travelled, an optional name. No AI, no extraction — the traveler says
/// where they went and the trip is saved as an ordinary trip, so "Your travels"
/// picks it up with no special handling anywhere downstream.
///
/// A screen rather than a dialog, matching the import flow: a new *creation
/// path* gets its own URL, and the destination list grows past what a dialog
/// holds comfortably.
class LogTripScreen extends ConsumerStatefulWidget {
  const LogTripScreen({super.key});

  @override
  ConsumerState<LogTripScreen> createState() => _LogTripScreenState();
}

class _LogTripScreenState extends ConsumerState<LogTripScreen> {
  final _searchController = TextEditingController();
  final _titleController = TextEditingController();
  Timer? _debounce;

  /// Debounced search text driving [placeSearchProvider] — the
  /// AddItineraryItemDialog pattern, so a fast typist costs one request.
  String _query = '';
  final List<LogTripDestination> _destinations = [];
  DateTimeRange? _dates;

  /// How far back the date picker reaches. A lifetime of travel, not the
  /// planner's year-1..year+3 window: this screen exists for the trip taken
  /// long before the account did.
  static const int _yearsBack = 60;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  void _add(LogTripDestination d) {
    setState(() {
      _destinations.add(d);
      _searchController.clear();
      _query = '';
    });
    _debounce?.cancel();
  }

  /// The typed-name escape hatch: whatever is in the search box becomes a
  /// destination with no coordinates. Keeps the screen usable end to end when
  /// place search finds nothing or is unavailable entirely.
  void _addTypedName() {
    final name = _searchController.text.trim();
    if (name.isEmpty) return;
    _add(LogTripDestination(name: name));
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - _yearsBack),
      // Today, not a future bound: this screen logs travel that HAPPENED. A
      // trip still under way belongs in the planner, and the traveled/planned
      // split would file it as planned anyway.
      lastDate: today,
      initialDateRange: _dates,
    );
    if (range != null && mounted) setState(() => _dates = range);
  }

  bool get _canSave => _destinations.isNotEmpty && _dates != null;

  Future<void> _save() async {
    if (!_canSave) return;
    FocusScope.of(context).unfocus();
    final range = _dates!;
    final trip = await ref.read(logTripProvider.notifier).save(
          destinations: [for (final d in _destinations) d.toJson()],
          startDate: _iso(range.start),
          endDate: _iso(range.end),
          title: _titleController.text.trim(),
        );
    if (!mounted || trip == null) return;
    Navigator.of(context).pushReplacement(
      locatedRoute(TripDetailScreen(tripId: trip.id), tripDetailLocation(trip.id)),
    );
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Year-bearing, unlike the shared [formatShortRange] shape: a logged trip is
  /// routinely decades old, so "Mar 3 – Mar 17" would be genuinely ambiguous
  /// here. Built inline rather than cached in date_formats.dart — that file
  /// exists for hot render paths, and this is a form that builds once.
  String _rangeLabel(DateTimeRange r) {
    final f = DateFormat.yMMMd();
    return '${f.format(r.start)} – ${f.format(r.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final state = ref.watch(logTripProvider);
    final range = _dates;

    return Scaffold(
      appBar: GradientAppBar(title: Text(l10n.logTripTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          PageContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.logTripExplainer,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.lg),

                // --- destinations ---
                Text(l10n.logTripDestinationsLabel,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  key: kLogTripSearchFieldKey,
                  controller: _searchController,
                  enabled: !state.saving,
                  decoration: InputDecoration(
                    hintText: l10n.logTripDestinationsHint,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: _onSearchChanged,
                  onSubmitted: (_) => _addTypedName(),
                ),
                if (_query.isNotEmpty) _buildResults(theme),
                if (_destinations.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (var i = 0; i < _destinations.length; i++)
                        _DestinationChip(
                          destination: _destinations[i],
                          onDeleted: state.saving
                              ? null
                              : () => setState(() => _destinations.removeAt(i)),
                        ),
                    ],
                  ),
                  // Stated before saving, not discovered afterwards: an
                  // unlocated destination counts as a city but draws no dot.
                  if (_destinations.any((d) => !d.isLocated)) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      l10n.logTripNoCoordsNote,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
                const SizedBox(height: AppSpacing.xl),

                // --- dates ---
                Text(l10n.logTripDatesLabel,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: state.saving ? null : _pickDates,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text(
                      range == null ? l10n.logTripPickDates : _rangeLabel(range)),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.logTripDatesRequired,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.xl),

                // --- title ---
                TextField(
                  controller: _titleController,
                  enabled: !state.saving,
                  decoration: InputDecoration(
                    labelText: l10n.logTripNameLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                if (state.error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: AppRadius.mdAll,
                    ),
                    child: Text(
                      state.error!.isNotEmpty ? state.error! : l10n.errorGeneric,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (state.saving) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: AppSpacing.md),
                ],
                FilledButton.icon(
                  key: kLogTripSaveButtonKey,
                  onPressed: state.saving || !_canSave ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(l10n.logTripSave),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    final l10n = context.l10n;
    return Consumer(builder: (context, ref, _) {
      final results = ref.watch(placeSearchProvider(_query));
      return results.when(
        data: (list) {
          if (list.isEmpty) {
            return _fallback(theme, l10n.itemDialogNoResults);
          }
          return Container(
            constraints: const BoxConstraints(maxHeight: 240),
            margin: const EdgeInsets.only(top: AppSpacing.sm),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: AppRadius.smAll,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (context, i) {
                final place = list[i] as PlaceSearchResult;
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.place_outlined),
                  title: Text(place.name),
                  subtitle:
                      place.address.isEmpty ? null : Text(place.address),
                  onTap: () => _add(LogTripDestination.fromPlace(place)),
                );
              },
            ),
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Center(child: CircularProgressIndicator()),
        ),
        // Search unavailable (e.g. no Places key) is not a dead end here —
        // the same "add it by name" route the empty result set offers.
        error: (e, _) => _fallback(theme, l10n.itemDialogSearchUnavailable),
      );
    });
  }

  /// The "search didn't help" branch: say why, then offer the typed name.
  Widget _fallback(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          TextButton.icon(
            onPressed: _addTypedName,
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.l10n.logTripAddByName(_searchController.text.trim())),
          ),
        ],
      ),
    );
  }
}

/// One picked destination. An unlocated one is visibly different — a struck
/// pin icon — so "this won't appear on the map" is legible at a glance rather
/// than only in the note below the row.
class _DestinationChip extends StatelessWidget {
  final LogTripDestination destination;
  final VoidCallback? onDeleted;

  const _DestinationChip({required this.destination, this.onDeleted});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InputChip(
      avatar: Icon(
        destination.isLocated ? Icons.place : Icons.location_off_outlined,
        size: 18,
        color: destination.isLocated
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      label: Text(destination.name),
      onDeleted: onDeleted,
    );
  }
}
