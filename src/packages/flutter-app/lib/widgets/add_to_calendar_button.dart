import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/trips_provider.dart';
import '../utils/calendar_links.dart';
import '../utils/errors.dart';
import '../utils/share_link.dart';
import '../utils/snack.dart';
import '../utils/tracked_launch.dart';

/// Per-event "Add to calendar" menu: Google Calendar via a prefilled
/// calendar.google.com link (pure URL — works offline-queued and for
/// read-only viewers), Apple Calendar via the token-gated per-event .ics
/// (needs an export token mint, so [appleEnabled] is false for viewers and
/// offline). Only rendered for dated events — call sites gate on the
/// calendar range resolvers.
class AddToCalendarButton extends ConsumerWidget {
  final String tripId;

  /// Server path segment for the .ics endpoint: stay | segment | item.
  final String kind;
  final String eventId;

  /// Analytics kind, matching the bookings naming: stay | transport | item.
  final String analyticsKind;
  final String title;
  final DateTime start;
  final DateTime endExclusive;
  final String? location;
  final String? details;

  /// All-day (the default) vs a timed event — mirror of the .ics semantics;
  /// pass the range resolver's `allDay`.
  final bool allDay;
  final bool appleEnabled;

  const AddToCalendarButton({
    super.key,
    required this.tripId,
    required this.kind,
    required this.eventId,
    required this.analyticsKind,
    required this.title,
    required this.start,
    required this.endExclusive,
    this.location,
    this.details,
    this.allDay = true,
    this.appleEnabled = false,
  });

  Future<void> _openGoogle(BuildContext context) async {
    await trackedLaunchUrl(
      context,
      googleCalendarUrl(
        title: title,
        start: start,
        endExclusive: endExclusive,
        allDay: allDay,
        location: location,
        details: details,
      ),
      provider: 'google_calendar',
      surface: 'event_calendar',
      tripId: tripId,
      kind: analyticsKind,
    );
  }

  Future<void> _openApple(BuildContext context, WidgetRef ref) async {
    try {
      final service = ref.read(tripsApiServiceProvider);
      final token = await service.mintExportToken(tripId);
      final url =
          exportEventIcsUrl(service.apiClient.baseUrl, token, kind, eventId);
      if (!context.mounted) return;
      await trackedLaunchUrl(
        context,
        url,
        provider: 'apple_calendar',
        surface: 'event_calendar',
        tripId: tripId,
        kind: analyticsKind,
      );
    } catch (e) {
      if (context.mounted) {
        showSnack(context,
            context.l10n.calendarExportFailed(friendlyError(context.l10n, e)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.event_outlined, size: 18),
      tooltip: context.l10n.calendarAddTo,
      onSelected: (choice) => switch (choice) {
        'google' => _openGoogle(context),
        _ => _openApple(context, ref),
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'google',
          child: ListTile(
            leading: const Icon(Icons.event_outlined),
            title: Text(context.l10n.calendarGoogle),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'apple',
          enabled: appleEnabled,
          child: ListTile(
            leading: const Icon(Icons.event_available_outlined),
            title: Text(context.l10n.calendarApple),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}
