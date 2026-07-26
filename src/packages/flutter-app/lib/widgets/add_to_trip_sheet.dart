import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/event.dart';
import '../models/itinerary_item.dart';
import '../models/local_recommendation.dart';
import '../models/trip.dart';
import '../navigation/app_nav.dart';
import '../providers/analytics_provider.dart';
import '../providers/trips_provider.dart';
import '../screens/trip_detail_screen.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/trip_days.dart';
import 'empty_state.dart';

/// What a browse surface (local rec card, event card, guide pin) hands the
/// add-to-trip sheet: the place fields that map onto an itinerary item, the
/// local-source attribution snapshots when the place came from a local, and
/// the analytics source tag (specs/add-to-itinerary).
class AddToTripPayload {
  final String name;
  final double? latitude;
  final double? longitude;
  final String? city;
  final String? address;
  final String? placeId;
  final String? category; // 'attraction' | 'restaurant'
  final String? localSourceName;
  final String? localRecommendationId;
  final String? eventDate; // YYYY-MM-DD, events only
  final String? eventTime; // HH:mm, events only
  final String source; // 'local_rec' | 'event' | 'guide_pin'

  const AddToTripPayload({
    required this.name,
    this.latitude,
    this.longitude,
    this.city,
    this.address,
    this.placeId,
    this.category,
    this.localSourceName,
    this.localRecommendationId,
    this.eventDate,
    this.eventTime,
    required this.source,
  });

  static String? _blankToNull(String s) => s.isEmpty ? null : s;

  /// A local recommendation or a guide pin (pins ARE recommendations); the
  /// caller distinguishes them only for analytics via [source].
  factory AddToTripPayload.fromLocalRec(
    LocalRecommendation rec, {
    String source = 'local_rec',
  }) {
    final category =
        (rec.category == 'attraction' || rec.category == 'restaurant')
            ? rec.category
            : null;
    return AddToTripPayload(
      name: rec.name,
      latitude: rec.latitude,
      longitude: rec.longitude,
      city: _blankToNull(rec.city),
      address: _blankToNull(rec.address),
      placeId: _blankToNull(rec.placeId),
      category: category,
      localSourceName: _blankToNull(rec.sourceName),
      localRecommendationId: rec.id,
      source: source,
    );
  }

  /// An event: venue becomes the address, and the date/time feed the day and
  /// time-of-day derivation once a trip is chosen. No attribution snapshots —
  /// events are not locally sourced.
  factory AddToTripPayload.fromEvent(Event event) {
    // (0,0) is the Event model's "no coordinates" placeholder.
    final hasCoords = event.latitude != 0 || event.longitude != 0;
    return AddToTripPayload(
      name: event.name,
      latitude: hasCoords ? event.latitude : null,
      longitude: hasCoords ? event.longitude : null,
      city: _blankToNull(event.city),
      address: _blankToNull(event.venue),
      category: 'attraction',
      eventDate: _blankToNull(event.startDate),
      eventTime: _blankToNull(event.startTime),
      source: 'event',
    );
  }

  /// morning / afternoon / evening from the event's start time; null when the
  /// time is absent or unparseable.
  String? get timeOfDay {
    final t = eventTime;
    if (t == null) return null;
    final hour = int.tryParse(t.split(':').first);
    if (hour == null || hour < 0 || hour > 23) return null;
    if (hour < 12) return 'morning';
    if (hour < 17) return 'afternoon';
    return 'evening';
  }
}

/// Opens the trip-and-day picker for [payload]. On success shows a snackbar
/// ("Added to <trip>", with a "View trip" shortcut when the target isn't the
/// screen the user is already on) and returns the updated trip so callers can
/// refresh in place; returns null when dismissed.
Future<Trip?> showAddToTripSheet(
  BuildContext context,
  AddToTripPayload payload, {
  String? currentTripId,
}) async {
  final l10n = context.l10n;
  final trip = await showModalBottomSheet<Trip>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // Cap the sheet on web/desktop — the picker is a narrow form, not a
    // full-bleed surface; Flutter centers a constrained modal sheet, and
    // phones stay unchanged (already under the cap).
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _AddToTripSheet(
      payload: payload,
      initialTripId: currentTripId,
    ),
  );
  if (trip != null && context.mounted) {
    // Capture the navigator now: the snackbar outlives a route pop (root
    // ScaffoldMessenger), so resolving it inside onPressed would look up a
    // deactivated context. NavigatorState outlives the launching route.
    final navigator = Navigator.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(l10n.addToTripAddedTo(trip.title)),
      action: trip.id == currentTripId
          ? null
          : SnackBarAction(
              label: l10n.addToTripViewTrip,
              onPressed: () => navigator.push(MaterialPageRoute(
                builder: (_) => TripDetailScreen(tripId: trip.id),
              )),
            ),
    ));
  }
  return trip;
}

/// Which failure the sheet is showing. Stored instead of formatted copy so the
/// message is resolved in `build` — `_selectTrip` runs from `initState`, where
/// `context.l10n` is not available (specs/i18n-spanish).
enum _SheetError { loadTrip, addPlace }

class _AddToTripSheet extends ConsumerStatefulWidget {
  final AddToTripPayload payload;
  final String? initialTripId;

  const _AddToTripSheet({required this.payload, this.initialTripId});

  @override
  ConsumerState<_AddToTripSheet> createState() => _AddToTripSheetState();
}

class _AddToTripSheetState extends ConsumerState<_AddToTripSheet> {
  String? _selectedTripId;
  Trip? _detail; // full trip for the selected id (items => days + dedupe)
  bool _detailLoading = false;
  int? _day;
  bool _submitting = false;
  _SheetError? _errorKind;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    // The browse surfaces are reachable without ever visiting My Trips, so the
    // list may not be loaded yet.
    final trips = ref.read(tripsProvider);
    if (trips.trips.isEmpty && !trips.loading) {
      Future.microtask(() => ref.read(tripsProvider.notifier).loadTrips());
    }
    if (widget.initialTripId != null) {
      _selectTrip(widget.initialTripId!);
    }
  }

  Future<void> _selectTrip(String tripId) async {
    setState(() {
      _selectedTripId = tripId;
      _detail = null;
      _detailLoading = true;
      _day = null;
      _errorKind = null;
      _errorDetail = null;
    });
    try {
      final detail = await ref.read(tripsApiServiceProvider).getTrip(tripId);
      if (!mounted || _selectedTripId != tripId) return;
      setState(() {
        _detail = detail;
        _detailLoading = false;
        _day = _eventDayFor(detail); // pre-select the event's day when it fits
      });
    } catch (e) {
      if (!mounted || _selectedTripId != tripId) return;
      setState(() {
        _detailLoading = false;
        _errorKind = _SheetError.loadTrip;
        _errorDetail = '$e';
      });
    }
  }

  /// The 1-based trip day the event's date falls on, or null when the trip has
  /// no start date, the date doesn't parse, or it lands outside the trip.
  int? _eventDayFor(Trip trip) {
    final eventDate = DateTime.tryParse(widget.payload.eventDate ?? '');
    if (eventDate == null) return null;
    return tripDayOn(trip.startDate, trip.endDate, eventDate);
  }

  /// How many day chips to offer: the later of the highest tagged item day and
  /// the trip's date span (so an empty dated trip still offers its real days).
  int _dayCount(Trip trip) => dayCount(
        trip.startDate,
        trip.endDate,
        (trip.items ?? const <ItineraryItem>[]).map((it) => it.day),
      );

  /// Already on the chosen trip? Matched by recommendation id when the payload
  /// carries one, with a case-insensitive name fallback (events have no id).
  bool _isDuplicate(Trip trip) {
    final items = trip.items ?? const <ItineraryItem>[];
    final recId = widget.payload.localRecommendationId;
    if (recId != null && items.any((i) => i.localRecommendationId == recId)) {
      return true;
    }
    final name = widget.payload.name.toLowerCase();
    return items.any((i) => i.name.toLowerCase() == name);
  }

  Future<void> _submit() async {
    final tripId = _selectedTripId;
    if (tripId == null) return;
    setState(() {
      _submitting = true;
      _errorKind = null;
      _errorDetail = null;
    });
    final p = widget.payload;
    final timeOfDay = p.timeOfDay;
    try {
      final updated =
          await ref.read(tripsApiServiceProvider).addItineraryItem(tripId, {
        'name': p.name,
        if (p.latitude != null && p.longitude != null) ...{
          'latitude': p.latitude,
          'longitude': p.longitude,
        },
        if (p.city != null) 'city': p.city,
        if (p.address != null) 'address': p.address,
        if (p.placeId != null) 'place_id': p.placeId,
        if (p.category != null) 'category': p.category,
        if (_day != null) 'day': _day,
        if (timeOfDay != null) 'time_of_day': timeOfDay,
        if (p.localSourceName != null) 'local_source_name': p.localSourceName,
        if (p.localRecommendationId != null)
          'local_recommendation_id': p.localRecommendationId,
      });
      // Fire-and-forget; never blocks or fails the add.
      ref
          .read(analyticsApiServiceProvider)
          .recordItineraryItemAdded(tripId: tripId, source: p.source);
      if (mounted) Navigator.pop(context, updated);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorKind = _SheetError.addPlace;
          _errorDetail = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final trips = ref.watch(tripsProvider);
    final detail = _detail;
    final duplicate = detail != null && _isDuplicate(detail);
    final detailText = _errorDetail ?? '';
    final errorText = switch (_errorKind) {
      _SheetError.loadTrip => l10n.addToTripLoadTripError(detailText),
      _SheetError.addPlace => l10n.addToTripAddPlaceError(detailText),
      null => null,
    };

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.addToTripTitle,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                widget.payload.name,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.md),
              Flexible(child: _tripList(trips, theme)),
              if (_detailLoading) ...[
                const SizedBox(height: AppSpacing.sm),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (detail != null) _daySection(detail, theme),
              if (duplicate) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: theme.colorScheme.tertiary),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        l10n.addToTripDuplicate,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.tertiary),
                      ),
                    ),
                  ],
                ),
              ],
              if (errorText != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(errorText,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: (detail == null || _submitting) ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(duplicate
                        ? l10n.addToTripAddAnyway
                        : l10n.addToTripTitle),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tripList(TripsState trips, ThemeData theme) {
    final l10n = context.l10n;
    if (trips.loading && trips.trips.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (trips.error != null && trips.trips.isEmpty) {
      // The min-Column wrapper keeps the sheet hugging its content:
      // EmptyState's Center would otherwise expand to the sheet's maxHeight.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmptyState(
            compact: true,
            icon: Icons.cloud_off,
            title: l10n.addToTripLoadTripsError,
            actions: [
              FilledButton(
                onPressed: () => ref.read(tripsProvider.notifier).loadTrips(),
                child: Text(l10n.commonRetry),
              ),
            ],
          ),
        ],
      );
    }
    if (trips.trips.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmptyState(
            compact: true,
            icon: Icons.luggage,
            title: l10n.addToTripNoTrips,
            actions: [
              FilledButton.icon(
                // No trip to add to: close the picker and land on the plan
                // tab, the same CTA the trips list's empty state offers.
                onPressed: () {
                  Navigator.pop(context);
                  ref.read(navIndexProvider.notifier).state = AppTab.plan.index;
                },
                icon: const Icon(Icons.auto_awesome),
                label: Text(l10n.tripsListPlanTrip),
              ),
            ],
          ),
        ],
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final t in trips.trips)
          ListTile(
            dense: true,
            leading: Icon(
              t.id == _selectedTripId
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: t.id == _selectedTripId
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: (t.cities?.isNotEmpty ?? false)
                ? Text(t.cities!.join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
            selected: t.id == _selectedTripId,
            onTap: _submitting ? null : () => _selectTrip(t.id),
          ),
      ],
    );
  }

  Widget _daySection(Trip trip, ThemeData theme) {
    final l10n = context.l10n;
    final count = _dayCount(trip);
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          ChoiceChip(
            label: Text(l10n.addToTripUnscheduled),
            selected: _day == null,
            onSelected: (_) => setState(() => _day = null),
          ),
          for (var d = 1; d <= count; d++)
            ChoiceChip(
              label: Text(l10n.addToTripDay(d)),
              selected: _day == d,
              onSelected: (_) => setState(() => _day = d),
            ),
        ],
      ),
    );
  }
}

/// The compact "Add to trip" affordance the browse cards render; kept here so
/// all three surfaces share one look.
class AddToTripButton extends StatelessWidget {
  final VoidCallback onPressed;

  /// The surface's accent (e.g. toolLocal / toolEvents) so the button sits
  /// naturally on its card.
  final Color? color;

  const AddToTripButton({super.key, required this.onPressed, this.color});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.add_location_alt_outlined,
          size: 20, color: color ?? AppColors.toolLocal),
      tooltip: context.l10n.addToTripTitle,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}
