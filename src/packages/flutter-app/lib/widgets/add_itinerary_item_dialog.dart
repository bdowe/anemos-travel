import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../models/itinerary_item.dart';
import '../models/place_search_result.dart';
import '../providers/places_api_provider.dart';
import '../providers/trips_provider.dart';
import '../utils/errors.dart';
import '../utils/trip_days.dart';

/// Category chips send canonical API values ('attraction', 'restaurant'), which
/// are never translated — only their display labels are (specs/i18n-spanish).
String _categoryLabel(AppLocalizations l10n, String value) => switch (value) {
      'attraction' => l10n.itemDialogCategoryAttraction,
      'restaurant' => l10n.itemDialogCategoryRestaurant,
      _ => value,
    };

/// Manually adds one place to a trip's itinerary: Google Places search picks a
/// real place (coordinates/address auto-filled), with a typed-name fallback
/// when search finds nothing or is unavailable. Pops `true` after saving.
class AddItineraryItemDialog extends ConsumerStatefulWidget {
  final Trip trip;
  final int? initialDay;

  const AddItineraryItemDialog({super.key, required this.trip, this.initialDay});

  @override
  ConsumerState<AddItineraryItemDialog> createState() =>
      _AddItineraryItemDialogState();
}

class _AddItineraryItemDialogState
    extends ConsumerState<AddItineraryItemDialog> {
  final _searchController = TextEditingController();
  final _nameController = TextEditingController();
  Timer? _debounce;
  String _query = ''; // debounced search text driving placeSearchProvider
  PlaceSearchResult? _selected;
  bool _manual = false;
  int? _day;
  String? _timeOfDay;
  String? _category;
  bool _saving = false;
  String? _error;

  /// Days offered by the Day dropdown: the same span as the map's day chips
  /// (trip date range or highest tagged day, whichever is later), so every
  /// real trip day is offered — including trailing days with no items yet —
  /// and any chip-selected [AddItineraryItemDialog.initialDay] has a
  /// matching entry.
  int get _dayCount => dayCount(
        widget.trip.startDate,
        widget.trip.endDate,
        (widget.trip.items ?? const <ItineraryItem>[]).map((i) => i.day),
      );

  /// The hub city of the chosen day's existing items, so the new place joins
  /// that city group. Without this the group key falls back to the address
  /// parse, whose locale spelling (e.g. "Lisboa") can split the group the AI
  /// tagged as "Lisbon".
  String? _cityForDay(int? day) {
    if (day == null) return null;
    for (final it in widget.trip.items ?? const <ItineraryItem>[]) {
      if (it.day != day) continue;
      final hub = it.dayTripFrom?.trim();
      if (hub != null && hub.isNotEmpty) return hub;
      final city = it.city?.trim();
      if (city != null && city.isNotEmpty) return city;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Only accept a day the dropdown actually offers; a stale out-of-range
    // value would trip DropdownButtonFormField's items assertion.
    final initial = widget.initialDay;
    _day = (initial != null && initial >= 1 && initial <= _dayCount + 1)
        ? initial
        : null;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final name = _manual ? _nameController.text.trim() : _selected?.name ?? '';
    if (name.isEmpty) {
      setState(() => _error = _manual
          ? l10n.itemDialogErrorEnterName
          : l10n.itemDialogErrorPickPlace);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final sel = _manual ? null : _selected;
      final city = _cityForDay(_day);
      await ref.read(tripsApiServiceProvider).addItineraryItem(widget.trip.id, {
        'name': name,
        if (sel != null) 'place_id': sel.placeId,
        if (sel != null && sel.address.isNotEmpty) 'address': sel.address,
        if (sel != null) 'latitude': sel.latitude,
        if (sel != null) 'longitude': sel.longitude,
        if (_category != null) 'category': _category,
        if (_timeOfDay != null) 'time_of_day': _timeOfDay,
        if (_day != null) 'day': _day,
        if (city != null) 'city': city,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = l10n.itemDialogErrorAddFailed(friendlyError(l10n, e));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.itemDialogTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_manual) ...[
                if (_selected == null) ...[
                  TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: l10n.itemDialogSearchLabel,
                      hintText: l10n.itemDialogSearchHint,
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: _onSearchChanged,
                  ),
                  if (_query.isNotEmpty) _buildResults(theme),
                ] else
                  Card(
                    margin: const EdgeInsets.only(bottom: 4),
                    child: ListTile(
                      leading: const Icon(Icons.place, color: Colors.green),
                      title: Text(_selected!.name),
                      subtitle: _selected!.address.isEmpty
                          ? null
                          : Text(_selected!.address),
                      trailing: IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: l10n.itemDialogPickDifferent,
                        onPressed: () => setState(() => _selected = null),
                      ),
                    ),
                  ),
                if (_selected == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _manual = true),
                      child: Text(l10n.itemDialogAddManually),
                    ),
                  ),
              ] else ...[
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.itemDialogPlaceNameLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _manual = false),
                    child: Text(l10n.itemDialogSearchInstead),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      initialValue: _day,
                      // Fill the field and ellipsize instead of overflowing
                      // when an item label outgrows the half-width column.
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.itemDialogDayLabel,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                            value: null,
                            child: Text(l10n.itemDialogUnscheduled)),
                        for (var d = 1; d <= _dayCount; d++)
                          DropdownMenuItem(
                              value: d, child: Text(l10n.itemDialogDayN(d))),
                        DropdownMenuItem(
                            value: _dayCount + 1,
                            child: Text(_dayCount == 0
                                ? l10n.itemDialogDayN(1)
                                : l10n.itemDialogNewDay(_dayCount + 1))),
                      ],
                      onChanged: (v) => setState(() => _day = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _timeOfDay,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.itemDialogTimeOfDayLabel,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      // Values are canonical API values — only labels are
                      // translated (specs/i18n-spanish).
                      items: [
                        DropdownMenuItem(
                            value: null, child: Text(l10n.itemDialogTimeAny)),
                        DropdownMenuItem(
                            value: 'morning',
                            child: Text(l10n.itemDialogTimeMorning)),
                        DropdownMenuItem(
                            value: 'afternoon',
                            child: Text(l10n.itemDialogTimeAfternoon)),
                        DropdownMenuItem(
                            value: 'evening',
                            child: Text(l10n.itemDialogTimeEvening)),
                      ],
                      onChanged: (v) => setState(() => _timeOfDay = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  // Canonical API values with translated labels.
                  for (final c in const ['attraction', 'restaurant'])
                    ChoiceChip(
                      label: Text(_categoryLabel(l10n, c)),
                      selected: _category == c,
                      onSelected: (sel) =>
                          setState(() => _category = sel ? c : null),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.itemDialogAdd),
        ),
      ],
    );
  }

  Widget _buildResults(ThemeData theme) {
    final l10n = context.l10n;
    return Consumer(builder: (context, ref, _) {
      final results = ref.watch(placeSearchProvider(_query));
      return results.when(
        data: (list) {
          if (list.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l10n.itemDialogNoResults),
            );
          }
          return Container(
            constraints: const BoxConstraints(maxHeight: 240),
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (context, i) {
                final place = list[i] as PlaceSearchResult;
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.place),
                  title: Text(place.name),
                  subtitle:
                      place.address.isEmpty ? null : Text(place.address),
                  onTap: () => setState(() => _selected = place),
                );
              },
            ),
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator()),
        ),
        // Search unavailable (e.g. no Places key): steer to manual entry.
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(12),
          child: Text(l10n.itemDialogSearchUnavailable,
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    });
  }
}
