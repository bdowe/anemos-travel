import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/trip_segment.dart';
import '../theme/spacing.dart';

/// Transport modes are canonical API values ('flight', 'train', …) sent to the
/// server, so they are never translated — only their display labels are
/// (specs/i18n-spanish). Anything unrecognized renders as-is.
String transportModeLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'flight' => l10n.bookingsModeFlight,
      'train' => l10n.bookingsModeTrain,
      'bus' => l10n.bookingsModeBus,
      'car' => l10n.bookingsModeCar,
      'ferry' => l10n.bookingsModeFerry,
      'other' => l10n.bookingsModeOther,
      _ => value,
    };

/// Icon for a canonical transport mode, paired with [transportModeLabel].
IconData transportModeIcon(String value) => switch (value) {
      'train' => Icons.train,
      'bus' => Icons.directions_bus,
      'car' => Icons.directions_car,
      'ferry' => Icons.directions_boat,
      'other' => Icons.commute,
      _ => Icons.flight,
    };

/// Bottom-sheet form for adding or editing a stay. Pops with the POST/PATCH
/// body map or null. With [initial] set the fields prefill and the labels flip
/// to editing.
class AddStaySheet extends StatefulWidget {
  final Accommodation? initial;

  /// Optional prefills for a fresh (non-edit) sheet, used by the Trip Health
  /// "Add a stay" fix. Ignored when [initial] is set. Dates are YYYY-MM-DD.
  final String? initialName;
  final String? initialAddress;
  final String? initialCheckIn;
  final String? initialCheckOut;

  const AddStaySheet({
    super.key,
    this.initial,
    this.initialName,
    this.initialAddress,
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
      if (widget.initialAddress != null) {
        _address.text = widget.initialAddress!;
      }
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
  final _priceNote = TextEditingController();
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
      _priceNote.text = s.priceNote ?? '';
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
    for (final c in [
      _origin,
      _destination,
      _provider,
      _url,
      _notes,
      _priceNote
    ]) {
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
      if (_priceNote.text.trim().isNotEmpty)
        'price_note': _priceNote.text.trim(),
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
                    label: Text(transportModeLabel(l10n, m)),
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
            // Parity with AddStaySheet: the column and API accepted
            // price_note all along — the form just never offered it.
            TextField(
              controller: _priceNote,
              decoration: InputDecoration(
                labelText: l10n.bookingsPriceNoteLabel,
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
