import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/trip_segment.dart';
import '../utils/calendar_links.dart';
import '../utils/tracked_launch.dart';
import '../utils/trip_format.dart';
import 'add_to_calendar_button.dart';
import 'booking_sheets.dart';
import 'booking_todo_card.dart' show kBookingRowLeadingSlot;

/// A confirmed booking's saved details, rendered as a slim indented line
/// under its [BookingTodoRow] in the itinerary (or standalone in detail-only
/// mode — viewers get no todos from the server, and unmatched confirmed
/// records have no row to sit under). Carries the affordances the retired
/// Bookings section gave confirmed rows: add-to-calendar, open link,
/// edit/delete, and — detail-only mode only — its own "Booked" checkbox
/// (matched rows are driven by the todo row's checkbox above instead).
class BookingDetailRow extends StatelessWidget {
  final String tripId;
  final Accommodation? stay;
  final TripSegment? segment;

  /// Edit/delete for the confirmed record. Null hides the icon (viewers,
  /// offline).
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// Detail-only mode: no todo row above, so this row shows its own compact
  /// "Booked" checkbox bound to the record's flag. Null hides it (matched
  /// rows — the todo row's checkbox is the single writer for both flags).
  final ValueChanged<bool>? onBookedChanged;

  /// Whether the checkbox renders at all in detail-only mode; read-only
  /// viewers see a disabled checkbox showing state (onBookedChanged null +
  /// showCheckbox true).
  final bool showCheckbox;

  /// Same gate as [AddToCalendarButton.appleEnabled].
  final bool appleCalendarEnabled;

  const BookingDetailRow.stay({
    super.key,
    required this.tripId,
    required Accommodation this.stay,
    this.onEdit,
    this.onDelete,
    this.onBookedChanged,
    this.showCheckbox = false,
    this.appleCalendarEnabled = false,
  }) : segment = null;

  const BookingDetailRow.segment({
    super.key,
    required this.tripId,
    required TripSegment this.segment,
    this.onEdit,
    this.onDelete,
    this.onBookedChanged,
    this.showCheckbox = false,
    this.appleCalendarEnabled = false,
  }) : stay = null;

  static IconData _modeIcon(String mode) => switch (mode) {
        'flight' => Icons.flight_takeoff,
        'train' => Icons.train_outlined,
        'bus' => Icons.directions_bus_outlined,
        'car' => Icons.directions_car_outlined,
        'ferry' => Icons.directions_boat_outlined,
        _ => Icons.route_outlined,
      };

  bool get _booked => stay != null ? stay!.booked : segment!.booked;

  // Not `stay?.url ?? segment!.url`: a stay with a null url must yield null,
  // not dereference the absent segment.
  String? get _url => stay != null ? stay!.url : segment!.url;

  /// Opens a saved booking's own link — still a booking handoff, so it counts
  /// toward the attach rate under the provider the user recorded (if any).
  Future<void> _open(BuildContext context) async {
    final provider = stay != null ? stay!.provider : segment!.provider;
    await trackedLaunchUrl(
      context,
      _url!,
      provider: (provider == null || provider.isEmpty)
          ? 'unknown'
          : provider.toLowerCase(),
      surface: 'bookings_hub',
      tripId: tripId,
      kind: stay != null ? 'stay' : 'transport',
    );
  }

  Widget? _calendarButton(AppLocalizations l10n) {
    if (stay case final a?) {
      final range = stayCalendarRange(a);
      if (range == null) return null;
      return AddToCalendarButton(
        tripId: tripId,
        kind: 'stay',
        eventId: a.id,
        analyticsKind: 'stay',
        title: l10n.calendarStayTitle(a.name),
        start: range.start,
        endExclusive: range.endExclusive,
        allDay: range.allDay,
        location: a.address,
        details: stayCalendarDetails(l10n, a),
        appleEnabled: appleCalendarEnabled,
      );
    }
    final s = segment!;
    final range = segmentCalendarRange(s);
    if (range == null) return null;
    return AddToCalendarButton(
      tripId: tripId,
      kind: 'segment',
      eventId: s.id,
      analyticsKind: 'transport',
      title: segmentCalendarTitle(l10n, s),
      start: range.start,
      endExclusive: range.endExclusive,
      allDay: range.allDay,
      details: segmentCalendarDetails(l10n, s),
      appleEnabled: appleCalendarEnabled,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;

    final String title;
    final String subtitle;
    if (stay case final a?) {
      title = a.name;
      subtitle = [
        if (a.provider != null && a.provider!.isNotEmpty) a.provider,
        if (tripDateRange(a.checkIn, a.checkOut) case final dates?) dates,
        if (a.address != null && a.address!.isNotEmpty) a.address,
      ].whereType<String>().join(' · ');
    } else {
      final s = segment!;
      title = [s.origin, s.destination].whereType<String>().join(' → ');
      subtitle = [
        transportModeLabel(l10n, s.mode),
        if (shortDateLabel(s.departDate) case final date?) date,
        if (s.provider != null && s.provider!.isNotEmpty) s.provider,
        if (s.notes != null && s.notes!.isNotEmpty) s.notes,
      ].whereType<String>().join(' · ');
    }
    final calendar = _calendarButton(l10n);

    // Indented to sit under the todo rows' title column (12px row padding +
    // the fixed leading slot + 8px gap); detail-only rows share the alignment
    // so mixed lists stay rhythmic.
    return Padding(
      padding: const EdgeInsets.only(
          left: 12 + kBookingRowLeadingSlot + 8, top: 2, bottom: 2),
      child: Row(
        children: [
          Icon(
            stay != null ? Icons.hotel_outlined : _modeIcon(segment!.mode),
            size: 16,
            color: muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _booked ? muted : null,
                    decoration: _booked ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
          if (calendar != null) calendar,
          if (_url != null && _url!.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: stay != null
                  ? l10n.bookingsOpenListing
                  : l10n.bookingsOpenBooking,
              onPressed: () => _open(context),
            ),
          if (onEdit != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: stay != null
                  ? l10n.bookingsEditStay
                  : l10n.bookingsEditTransport,
              onPressed: onEdit,
            ),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: stay != null
                  ? l10n.bookingsRemoveStay
                  : l10n.bookingsRemoveTransport,
              onPressed: onDelete,
            ),
          if (showCheckbox)
            Checkbox(
              value: _booked,
              onChanged: onBookedChanged == null
                  ? null
                  : (v) => onBookedChanged!(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }
}
