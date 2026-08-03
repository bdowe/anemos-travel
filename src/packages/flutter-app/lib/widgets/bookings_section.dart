import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/trip.dart';
import '../models/trip_segment.dart';
import '../theme/spacing.dart';
import '../utils/calendar_links.dart';
import '../utils/tracked_launch.dart';
import '../utils/trip_format.dart';
import 'add_to_calendar_button.dart';
import 'section_header.dart';

/// Transport modes are canonical API values ('flight', 'train', …) sent to the
/// server, so they are never translated — only their display labels are
/// (specs/i18n-spanish). Anything unrecognized renders as-is.
String _modeLabel(AppLocalizations l10n, String value) => switch (value) {
      'flight' => l10n.bookingsModeFlight,
      'train' => l10n.bookingsModeTrain,
      'bus' => l10n.bookingsModeBus,
      'car' => l10n.bookingsModeCar,
      'ferry' => l10n.bookingsModeFerry,
      'other' => l10n.bookingsModeOther,
      _ => value,
    };

/// The "Bookings" hub in trip detail: the confirmed stays and transport
/// segments the user has actually saved, plus — via the [otherBookings]
/// slot — the residual booking-todos that didn't match a city group.
/// Itinerary-seeded drafts (auto=true) are never rendered: the inline
/// itinerary rows are the primary book+track surface, and the drafts sync
/// keeps running purely to keep the server rows fresh for old clients.
/// Callbacks land in the screen, which persists via the
/// accommodations/segments endpoints and reloads the trip.
class BookingsSection extends StatelessWidget {
  final Trip trip;

  /// Sync-owned lists (drafts + confirmed) held by the screen — the booking
  /// drafts sync replaces them after each load, so they're passed in rather
  /// than read from the immutable [trip].
  final List<Accommodation> stays;
  final List<TripSegment> segments;
  final VoidCallback onAddStay;
  final void Function(Accommodation) onDeleteStay;
  final void Function(Accommodation) onEditStay;
  final VoidCallback onAddSegment;
  final void Function(TripSegment) onDeleteSegment;
  final void Function(TripSegment) onEditSegment;

  /// "Booked" checkbox toggles. Null disables the checkboxes (offline), like
  /// the reorder callbacks; in read-only mode they render disabled but still
  /// show state.
  final void Function(Accommodation, bool)? onStayBookedChanged;
  final void Function(TripSegment, bool)? onSegmentBookedChanged;

  /// Drag-reorder callbacks, `ReorderableListView.onReorder`-shaped. Null
  /// disables reordering for that group (viewer follows, offline). Indexes
  /// refer to [stays]/[segments] directly — when reordering is enabled the
  /// widget is not read-only, so the visible list IS the passed-in list.
  final void Function(int oldIndex, int newIndex)? onReorderStays;
  final void Function(int oldIndex, int newIndex)? onReorderSegments;

  /// Read-only mode (viewer follows): stays and transport render without the
  /// add buttons and edit/delete icons, and Suggested drafts are hidden
  /// entirely (the server already withholds them from viewers).
  final bool readOnly;

  /// Residual booking-todos rendered as the "Other" sub-group. Built by the
  /// screen — its callbacks (open-link factory, flight-leg labels, todo
  /// dialogs) are screen-coupled. Null hides the sub-group and its header;
  /// pass null rather than an empty list widget (see the empty-scroll-view
  /// note in [build]).
  final Widget? otherBookings;

  /// Opens the add-booking-todo dialog; rendered as the section's trailing
  /// "Add booking" footer when not read-only. Null renders it disabled
  /// (offline), mirroring the reorder callbacks.
  final VoidCallback? onAddBooking;

  /// Whether the "Apple Calendar (.ics)" entry of the per-row Add-to-calendar
  /// menu is enabled. False for viewers (they can't mint export tokens) and
  /// offline; the Google entry is a pure URL and stays available regardless.
  final bool appleCalendarEnabled;

  /// False when a parent (trip detail's collapsed-section row) already
  /// renders the title; the Add stay / Add transport actions then move to a
  /// right-aligned first body row so nothing is lost.
  final bool showHeader;

  const BookingsSection({
    super.key,
    required this.trip,
    required this.stays,
    required this.segments,
    required this.onAddStay,
    required this.onDeleteStay,
    required this.onEditStay,
    required this.onAddSegment,
    required this.onDeleteSegment,
    required this.onEditSegment,
    this.onStayBookedChanged,
    this.onSegmentBookedChanged,
    this.onReorderStays,
    this.onReorderSegments,
    this.readOnly = false,
    this.otherBookings,
    this.onAddBooking,
    this.appleCalendarEnabled = false,
    this.showHeader = true,
  });

  /// Calendar-event title for a segment, mirroring the Go export's
  /// `capitalize(mode) + ": " + segmentRoute(s)`.
  /// Calendar event title for a transport segment.
  ///
  /// This MUST stay byte-identical to the Go `.ics` export
  /// (calendar_handler.go `segmentEventFieldsIn`): the traveler picks between
  /// a Google Calendar link built here and an `.ics` file built there for the
  /// SAME event, so any divergence shows up as two differently-named entries.
  /// That is why the empty-route case falls back to the mode label rather than
  /// returning the mode alone, matching Go's `segmentRouteIn`.
  static String _segmentCalendarTitle(AppLocalizations l10n, TripSegment s) {
    final mode = _calendarModeLabel(l10n, s.mode);
    final route = [s.origin, s.destination].whereType<String>().join(' → ');
    return l10n.calendarSegmentTitle(mode, route.isEmpty ? mode : route);
  }

  /// Mirrors Go's `localizedMode`: known modes translate, anything else keeps
  /// its raw value capitalized.
  static String _calendarModeLabel(AppLocalizations l10n, String mode) =>
      switch (mode.trim().toLowerCase()) {
        'flight' => l10n.calendarModeFlight,
        'train' => l10n.calendarModeTrain,
        'bus' => l10n.calendarModeBus,
        'car' => l10n.calendarModeCar,
        'ferry' => l10n.calendarModeFerry,
        'other' => l10n.calendarModeOther,
        '' => '',
        _ => mode[0].toUpperCase() + mode.substring(1),
      };

  static IconData _modeIcon(String mode) => switch (mode) {
        'flight' => Icons.flight_takeoff,
        'train' => Icons.train_outlined,
        'bus' => Icons.directions_bus_outlined,
        'car' => Icons.directions_car_outlined,
        'ferry' => Icons.directions_boat_outlined,
        _ => Icons.route_outlined,
      };

  /// Opens a saved booking's own link — still a booking handoff, so it counts
  /// toward the attach rate under the provider the user recorded (if any).
  Future<void> _open(BuildContext context, String url,
      {String? provider, required String kind}) async {
    await trackedLaunchUrl(
      context,
      url,
      provider: (provider == null || provider.isEmpty)
          ? 'unknown'
          : provider.toLowerCase(),
      surface: 'bookings_hub',
      tripId: trip.id,
      kind: kind,
    );
  }

  /// Compact "Booked" checkbox for confirmed rows, shrunk to sit in the
  /// trailing icon row (same treatment as BookingTodoRow's). A null
  /// [onChanged] renders it disabled but still showing state.
  Widget _bookedCheckbox(
          {required bool value, required void Function(bool)? onChanged}) =>
      Checkbox(
        value: value,
        onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  /// Muted + struck-through once booked, mirroring the checklist rows.
  TextStyle? _bookedTitleStyle(ThemeData theme, bool booked) => booked
      ? TextStyle(
          color: theme.colorScheme.onSurfaceVariant,
          decoration: TextDecoration.lineThrough,
        )
      : null;

  Widget _dragHandle(ThemeData theme, int index) =>
      ReorderableDragStartListener(
        index: index,
        child: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.sm),
          child: Icon(Icons.drag_indicator,
              color: theme.colorScheme.onSurfaceVariant),
        ),
      );

  Widget _subHeader(ThemeData theme, String label) => Padding(
        padding:
            const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
        child: Text(
          label,
          style: theme.textTheme.titleSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Drafts (auto=true) never render, for anyone: legacy rows still arrive
    // in editor payloads (and stale cached copies), but the inline itinerary
    // rows own the suggested-booking flow now.
    final visibleStays =
        stays.where((a) => !a.auto).toList(growable: false);
    final visibleSegments =
        segments.where((s) => !s.auto).toList(growable: false);
    final canDragStays =
        onReorderStays != null && !readOnly && visibleStays.length > 1;
    final canDragSegments =
        onReorderSegments != null && !readOnly && visibleSegments.length > 1;

    // The button pair alone can outgrow a small phone's width, so it must be
    // able to break into two lines itself (Wrap, not Row).
    final addActions = readOnly
        ? null
        : Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: onAddStay,
                icon: const Icon(Icons.hotel_outlined, size: 18),
                label: Text(l10n.bookingsAddStay),
              ),
              TextButton.icon(
                onPressed: onAddSegment,
                icon: const Icon(Icons.route_outlined, size: 18),
                label: Text(l10n.bookingsAddTransport),
              ),
            ],
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader)
          SectionHeader(title: l10n.bookingsTitle, action: addActions)
        else if (addActions != null)
          Align(alignment: Alignment.centerRight, child: addActions),
        if (visibleStays.isEmpty &&
            visibleSegments.isEmpty &&
            otherBookings == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text(
              l10n.bookingsEmptyMessage,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        // Only built when non-empty: ReorderableListView is itself a scroll
        // view, and a pair of always-present empty ones would pollute the
        // page's scrollable tree (and every find.byType(CustomScrollView)).
        if (visibleStays.isNotEmpty) ...[
          _subHeader(theme, l10n.bookingsStays),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            itemCount: visibleStays.length,
            onReorder: (oldIndex, newIndex) =>
                onReorderStays?.call(oldIndex, newIndex),
            itemBuilder: (context, i) {
              final a = visibleStays[i];
              return Card(
                key: ValueKey(a.id),
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: ListTile(
                  leading: const Icon(Icons.hotel_outlined),
                  title: Text(a.name,
                      style: _bookedTitleStyle(theme, a.booked)),
                  subtitle: Text(
                    [
                      if (a.provider != null && a.provider!.isNotEmpty)
                        a.provider,
                      if (tripDateRange(a.checkIn, a.checkOut)
                          case final dates?)
                        dates,
                      if (a.address != null && a.address!.isNotEmpty) a.address,
                    ].whereType<String>().join(' · '),
                  ),
                  trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (stayCalendarRange(a) case final range?)
                              AddToCalendarButton(
                                tripId: trip.id,
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
                              ),
                            if (a.url != null && a.url!.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.open_in_new, size: 18),
                                tooltip: l10n.bookingsOpenListing,
                                onPressed: () => _open(context, a.url!,
                                    provider: a.provider, kind: 'stay'),
                              ),
                            if (!readOnly) ...[
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                tooltip: l10n.bookingsEditStay,
                                onPressed: () => onEditStay(a),
                              ),
                              IconButton(
                                icon:
                                    const Icon(Icons.delete_outline, size: 18),
                                tooltip: l10n.bookingsRemoveStay,
                                onPressed: () => onDeleteStay(a),
                              ),
                            ],
                            _bookedCheckbox(
                              value: a.booked,
                              onChanged:
                                  (readOnly || onStayBookedChanged == null)
                                      ? null
                                      : (v) => onStayBookedChanged!(a, v),
                            ),
                            if (canDragStays) _dragHandle(theme, i),
                          ],
                        ),
                ),
              );
            },
          ),
        ],
        if (visibleSegments.isNotEmpty) ...[
          _subHeader(theme, l10n.bookingsTransport),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            itemCount: visibleSegments.length,
            onReorder: (oldIndex, newIndex) =>
                onReorderSegments?.call(oldIndex, newIndex),
            itemBuilder: (context, i) {
              final s = visibleSegments[i];
              return Card(
                key: ValueKey(s.id),
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: ListTile(
                  leading: Icon(_modeIcon(s.mode)),
                  title: Text(
                    [s.origin, s.destination]
                        .whereType<String>()
                        .join(' → '),
                    style: _bookedTitleStyle(theme, s.booked),
                  ),
                  subtitle: Text(
                    [
                      _modeLabel(l10n, s.mode),
                      if (shortDateLabel(s.departDate) case final date?) date,
                      if (s.provider != null && s.provider!.isNotEmpty)
                        s.provider,
                      if (s.notes != null && s.notes!.isNotEmpty) s.notes,
                    ].whereType<String>().join(' · '),
                  ),
                  trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (segmentCalendarRange(s) case final range?)
                              AddToCalendarButton(
                                tripId: trip.id,
                                kind: 'segment',
                                eventId: s.id,
                                analyticsKind: 'transport',
                                title: _segmentCalendarTitle(l10n, s),
                                start: range.start,
                                endExclusive: range.endExclusive,
                                allDay: range.allDay,
                                details: segmentCalendarDetails(l10n, s),
                                appleEnabled: appleCalendarEnabled,
                              ),
                            if (s.url != null && s.url!.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.open_in_new, size: 18),
                                tooltip: l10n.bookingsOpenBooking,
                                onPressed: () => _open(context, s.url!,
                                    provider: s.provider, kind: 'transport'),
                              ),
                            if (!readOnly) ...[
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                tooltip: l10n.bookingsEditTransport,
                                onPressed: () => onEditSegment(s),
                              ),
                              IconButton(
                                icon:
                                    const Icon(Icons.delete_outline, size: 18),
                                tooltip: l10n.bookingsRemoveTransport,
                                onPressed: () => onDeleteSegment(s),
                              ),
                            ],
                            _bookedCheckbox(
                              value: s.booked,
                              onChanged:
                                  (readOnly || onSegmentBookedChanged == null)
                                      ? null
                                      : (v) => onSegmentBookedChanged!(s, v),
                            ),
                            if (canDragSegments) _dragHandle(theme, i),
                          ],
                        ),
                ),
              );
            },
          ),
        ],
        if (otherBookings != null) ...[
          _subHeader(theme, l10n.bookingsOther),
          otherBookings!,
        ],
        if (!readOnly)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onAddBooking,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.bookingsAddBooking),
            ),
          ),
      ],
    );
  }
}

/// Bottom-sheet form for adding or editing a stay. Pops with the POST/PATCH
/// body map or null. With [initial] set the fields prefill and the labels flip
/// to editing.
class AddStaySheet extends StatefulWidget {
  final Accommodation? initial;

  /// Optional prefills for a fresh (non-edit) sheet, used by the Trip Health
  /// "Add a stay" fix. Ignored when [initial] is set. Dates are YYYY-MM-DD.
  final String? initialName;
  final String? initialCheckIn;
  final String? initialCheckOut;

  const AddStaySheet({
    super.key,
    this.initial,
    this.initialName,
    this.initialCheckIn,
    this.initialCheckOut,
  });

  @override
  State<AddStaySheet> createState() => _AddStaySheetState();
}

class _AddStaySheetState extends State<AddStaySheet> {
  final _name = TextEditingController();
  final _provider = TextEditingController();
  final _url = TextEditingController();
  final _address = TextEditingController();
  final _priceNote = TextEditingController();
  DateTime? _checkIn;
  DateTime? _checkOut;

  @override
  void initState() {
    super.initState();
    final a = widget.initial;
    if (a != null) {
      _name.text = a.name;
      _provider.text = a.provider ?? '';
      _url.text = a.url ?? '';
      _address.text = a.address ?? '';
      _priceNote.text = a.priceNote ?? '';
      _checkIn = a.checkIn == null ? null : DateTime.tryParse(a.checkIn!);
      _checkOut = a.checkOut == null ? null : DateTime.tryParse(a.checkOut!);
    } else {
      if (widget.initialName != null) _name.text = widget.initialName!;
      _checkIn = widget.initialCheckIn == null
          ? null
          : DateTime.tryParse(widget.initialCheckIn!);
      _checkOut = widget.initialCheckOut == null
          ? null
          : DateTime.tryParse(widget.initialCheckOut!);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _provider, _url, _address, _priceNote]) {
      c.dispose();
    }
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (range != null) {
      setState(() {
        _checkIn = range.start;
        _checkOut = range.end;
      });
    }
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(<String, dynamic>{
      'name': name,
      if (_provider.text.trim().isNotEmpty) 'provider': _provider.text.trim(),
      if (_url.text.trim().isNotEmpty) 'url': _url.text.trim(),
      if (_address.text.trim().isNotEmpty) 'address': _address.text.trim(),
      if (_priceNote.text.trim().isNotEmpty)
        'price_note': _priceNote.text.trim(),
      if (_checkIn != null) 'check_in': _fmt(_checkIn!),
      if (_checkOut != null) 'check_out': _fmt(_checkOut!),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final editing = widget.initial != null;
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
            Text(editing ? l10n.bookingsEditStay : l10n.bookingsAddAStay,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayNameLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _provider,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayProviderLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayUrlLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _address,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayAddressLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickRange,
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(
                      _checkIn != null && _checkOut != null
                          ? '${_fmt(_checkIn!)} → ${_fmt(_checkOut!)}'
                          : l10n.bookingsCheckInOut,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _priceNote,
              decoration: InputDecoration(
                labelText: l10n.bookingsPriceNoteLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _save,
                  child: Text(editing ? l10n.commonSave : l10n.bookingsAddStay),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-sheet form for adding or editing a transport segment. Pops with the
/// POST/PATCH body map or null. With [initial] set the fields prefill and the
/// labels flip to editing.
class AddSegmentSheet extends StatefulWidget {
  final TripSegment? initial;

  /// Optional prefills for a fresh (non-edit) sheet, used by the Trip Health
  /// "Add transport" fix. Ignored when [initial] is set. Date is YYYY-MM-DD.
  final String? initialOrigin;
  final String? initialDestination;
  final String? initialMode;
  final String? initialDepartDate;

  const AddSegmentSheet({
    super.key,
    this.initial,
    this.initialOrigin,
    this.initialDestination,
    this.initialMode,
    this.initialDepartDate,
  });

  @override
  State<AddSegmentSheet> createState() => _AddSegmentSheetState();
}

class _AddSegmentSheetState extends State<AddSegmentSheet> {
  final _origin = TextEditingController();
  final _destination = TextEditingController();
  final _provider = TextEditingController();
  final _url = TextEditingController();
  final _notes = TextEditingController();
  String _mode = 'flight';
  DateTime? _departDate;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    if (s != null) {
      _origin.text = s.origin ?? '';
      _destination.text = s.destination ?? '';
      _provider.text = s.provider ?? '';
      _url.text = s.url ?? '';
      _notes.text = s.notes ?? '';
      _mode = s.mode;
      _departDate =
          s.departDate == null ? null : DateTime.tryParse(s.departDate!);
    } else {
      if (widget.initialOrigin != null) _origin.text = widget.initialOrigin!;
      if (widget.initialDestination != null) {
        _destination.text = widget.initialDestination!;
      }
      if (widget.initialMode != null) _mode = widget.initialMode!;
      _departDate = widget.initialDepartDate == null
          ? null
          : DateTime.tryParse(widget.initialDepartDate!);
    }
  }

  @override
  void dispose() {
    for (final c in [_origin, _destination, _provider, _url, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked != null) setState(() => _departDate = picked);
  }

  void _save() {
    final origin = _origin.text.trim();
    final destination = _destination.text.trim();
    if (origin.isEmpty || destination.isEmpty) return;
    Navigator.of(context).pop(<String, dynamic>{
      'mode': _mode,
      'origin': origin,
      'destination': destination,
      if (_departDate != null) 'depart_date': _fmt(_departDate!),
      if (_provider.text.trim().isNotEmpty) 'provider': _provider.text.trim(),
      if (_url.text.trim().isNotEmpty) 'url': _url.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final editing = widget.initial != null;
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
            Text(
                editing
                    ? l10n.bookingsEditTransport
                    : l10n.bookingsAddTransport,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: 8,
              children: [
                for (final m in const [
                  'flight',
                  'train',
                  'bus',
                  'car',
                  'ferry',
                  'other',
                ])
                  ChoiceChip(
                    label: Text(_modeLabel(l10n, m)),
                    selected: _mode == m,
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _origin,
                    decoration: InputDecoration(
                      labelText: l10n.bookingsSegmentFromLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    controller: _destination,
                    decoration: InputDecoration(
                      labelText: l10n.bookingsSegmentToLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.today, size: 18),
              label: Text(
                _departDate != null
                    ? _fmt(_departDate!)
                    : l10n.bookingsDepartureDate,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _provider,
              decoration: InputDecoration(
                labelText: l10n.bookingsSegmentProviderLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: l10n.bookingsSegmentUrlLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _notes,
              decoration: InputDecoration(
                labelText: l10n.bookingsNotesLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _save,
                  child: Text(
                      editing ? l10n.commonSave : l10n.bookingsAddTransport),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
