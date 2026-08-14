import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/event.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import 'event_card.dart';

/// Opens a city's full events list as a modal bottom sheet — what the trip
/// detail rail's "See all" leads to.
///
/// The rail shows a day-spread shortlist (see utils/event_picks.dart); this is
/// the unfiltered escape hatch, so every event the server returned stays
/// reachable. [events] is the SAME list the rail was built from, snapshotted
/// at press time — `eventsByCityProvider` is not autoDispose and already holds
/// it, so opening the sheet costs no network.
///
/// No Scaffold inside the sheet, so the framework's Escape→dismiss handling
/// works as-is (a nested Scaffold would swallow DismissIntent — the
/// trip_map_screen trap).
Future<void> showCityEventsSheet(
  BuildContext context, {
  required String city,
  required List<Event> events,
  required void Function(Event) onAddToTrip,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Width cap centers the sheet on desktop, same as the wear/health sheets:
    // event rows read stranded at full bleed.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
            child: CityEventsSheetBody(
              city: city,
              events: events,
              onAddToTrip: onAddToTrip,
            ),
          ),
        ),
      );
    },
  );
}

/// The sheet body: title, then every event as an [EventCard] under a header
/// for the day it falls on. Public so tests can scope finders to the sheet.
class CityEventsSheetBody extends StatelessWidget {
  final String city;
  final List<Event> events;
  final void Function(Event) onAddToTrip;

  const CityEventsSheetBody({
    super.key,
    required this.city,
    required this.events,
    required this.onAddToTrip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    // Chronological, grouped by day, in the order the server returned them
    // (`sort=date,asc`). Grouping only — no reordering, so an event can never
    // be somewhere the rail's chronological picks wouldn't predict.
    final days = <String, List<Event>>{};
    for (final e in events) {
      days.putIfAbsent(e.startDate, () => <Event>[]).add(e);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(
            children: [
              Icon(Icons.local_activity, size: 20, color: AppColors.toolEvents),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  l10n.tripEventsInCity(city),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        for (final entry in days.entries) ...[
          Padding(
            padding: const EdgeInsets.only(
                top: AppSpacing.sm, bottom: AppSpacing.xs),
            child: Text(
              // The day header states the date once; the cards below it drop
              // theirs (showDate: false) rather than repeating it per row.
              eventDayLabel(entry.value.first),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final event in entry.value)
            EventCard(
              event: event,
              showDate: false,
              onAddToTrip: () {
                // Pop first: _addToTrip opens its own modal sheet, and
                // stacking one on this barrier strands the confirmation
                // snackbar behind two routes.
                final route = ModalRoute.of(context);
                if (route?.isCurrent ?? false) Navigator.of(context).pop();
                onAddToTrip(event);
              },
            ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md),
          child: Text(
            // Says where the list comes from — it is one provider's catalogue,
            // not everything happening in the city.
            l10n.tripEventsSource,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
