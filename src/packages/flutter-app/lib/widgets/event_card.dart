import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/event.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/tracked_launch.dart';
import 'add_to_trip_sheet.dart';

/// "Wed, Jul 1 · 20:00" — date via intl's locale-aware [DateFormat.MMMEd]
/// (which reads Intl.defaultLocale, set by the locale provider — same pattern
/// as lib/utils/trip_format.dart), with the raw HH:mm appended. Kept here as a
/// presentation helper so the [Event] model stays a pure JSON mirror.
/// Unparseable dates fall back to the raw string.
String eventWhenLabel(Event event) {
  final d = DateTime.tryParse(event.startDate);
  final date = d == null ? event.startDate : DateFormat.MMMEd().format(d);
  return event.startTime.isEmpty ? date : '$date · ${event.startTime}';
}

/// A single local event: name, when, venue/category, opening the ticket/info
/// page externally on tap. Styled to sit beside itinerary and booking rows.
class EventCard extends StatelessWidget {
  final Event event;

  /// When set, the card shows an "Add to trip" action (signed-in users only —
  /// pass null for anonymous sessions). Kept separate from the card's tap,
  /// which opens the ticket page.
  final VoidCallback? onAddToTrip;

  const EventCard({super.key, required this.event, this.onAddToTrip});

  Future<void> _open(BuildContext context) async {
    if (event.url.isEmpty) return;
    await trackedLaunchUrl(context, event.url,
        provider: 'ticketmaster', surface: 'event_card');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.toolEvents;
    final subtitle = [
      if (event.venue.isNotEmpty) event.venue,
      if (event.category.isNotEmpty) event.category,
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: event.url.isEmpty ? null : () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.local_activity, size: 20, color: accent),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.name,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      eventWhenLabel(event),
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: accent, fontWeight: FontWeight.w600),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (onAddToTrip != null)
                AddToTripButton(onPressed: onAddToTrip!, color: accent),
              if (event.url.isNotEmpty)
                Icon(Icons.open_in_new,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
