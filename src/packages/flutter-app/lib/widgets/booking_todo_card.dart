import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/booking_todo.dart';
import 'booking_sheets.dart' show transportModeIcon, transportModeLabel;

IconData _kindIcon(BookingTodo todo) {
  switch (todo.kind) {
    case 'transport':
      // A per-leg mode override names the icon exactly; otherwise the
      // provider the leg was derived with implies it.
      if (todo.mode case final mode?) return transportModeIcon(mode);
      switch (todo.provider) {
        case 'ferry':
          return Icons.directions_boat;
        case 'rome2rio': // ground leg on a driving/train/bus trip
          return Icons.directions;
        default:
          return Icons.flight;
      }
    case 'stay':
      return Icons.hotel;
    default:
      return Icons.check_circle_outline;
  }
}

/// Provider codes map to brand names, which are never translated — only the
/// surrounding "Open in ..." phrasing is (specs/i18n-spanish).
String? _providerBrand(String? provider) => switch (provider) {
      'airbnb' => 'Airbnb',
      'booking' => 'Booking.com',
      'google_flights' => 'Google Flights',
      'ferry' => 'Ferryhopper',
      'kayak' => 'Kayak',
      'rome2rio' => 'Rome2Rio',
      _ => null,
    };

String _providerOpenLabel(
    AppLocalizations l10n, BookingTodo todo, String? override,
    {bool compact = false}) {
  if (override != null) return override;
  final brand = _providerBrand(todo.provider);
  if (compact) {
    // Narrow rows: the brand alone ("Airbnb") — brands are never translated,
    // so no extra keys beyond the generic short fallback.
    return brand ?? l10n.bookingCardOpenSearchShort;
  }
  return brand == null
      ? l10n.bookingCardOpenSearch
      : l10n.bookingCardOpenIn(brand);
}

/// Width of the fixed leading slot in a [BookingTodoRow]: the 18px kind icon
/// plus the 16px mode-menu caret (see [_ModeMenu]). Every row reserves the
/// full slot — stay rows, transport rows with the mode menu, and transport
/// rows without it — so their titles all start at the same x.
/// BookingDetailRow derives its indent from this; change it here only.
const double kBookingRowLeadingSlot = 34; // 18 icon + 16 caret

/// A styled booking checklist card: an icon by kind, the title + dates, a
/// "Booked" checkbox, and a button that opens the pre-filled search link.
class BookingTodoCard extends StatelessWidget {
  final BookingTodo todo;
  final ValueChanged<bool> onBookedChanged;
  final VoidCallback? onOpen;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// Overrides the open-button text (e.g. 'Find flights' when the action opens
  /// the in-app flight search instead of an external provider link).
  final String? openLabelOverride;

  /// Optional drag affordance (e.g. a ReorderableDragStartListener-wrapped
  /// drag_indicator) rendered at the end of the title row. The card stays
  /// index-agnostic — the list that owns the ordering builds the listener.
  final Widget? dragHandle;

  const BookingTodoCard({
    super.key,
    required this.todo,
    required this.onBookedChanged,
    this.onOpen,
    this.onEdit,
    this.onDelete,
    this.openLabelOverride,
    this.dragHandle,
  });

  IconData get _icon => _kindIcon(todo);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icon, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(todo.title, style: theme.textTheme.titleSmall),
                      if (todo.subtitle != null && todo.subtitle!.isNotEmpty)
                        Text(
                          todo.subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (onEdit != null)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: l10n.bookingCardEdit,
                    onPressed: onEdit,
                  ),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.bookingCardRemove,
                    onPressed: onDelete,
                  ),
                if (dragHandle != null) dragHandle!,
              ],
            ),
            Row(
              children: [
                Checkbox(
                  value: todo.booked,
                  onChanged: (v) => onBookedChanged(v ?? false),
                ),
                Text(l10n.bookingCardBooked,
                    style: theme.textTheme.bodyMedium),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label:
                      Text(_providerOpenLabel(l10n, todo, openLabelOverride)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A slim one-line booking row for embedding inside the itinerary's city
/// groups: kind icon, title + dates, a compact "Booked" checkbox, and the
/// open-search action. Auto bookings only — no delete affordance.
class BookingTodoRow extends StatelessWidget {
  final BookingTodo todo;
  final ValueChanged<bool> onBookedChanged;
  final VoidCallback? onOpen;

  /// Same override as [BookingTodoCard.openLabelOverride].
  final String? openLabelOverride;

  /// "Add details…": promotes this todo to a confirmed accommodation/segment
  /// via a prefilled add-sheet. Confirmed records are what viewers see and
  /// what calendar export / Tonight / map stay pins read, so this is the
  /// one-tap replacement for the retired Suggested-draft "Keep" flow. Null
  /// hides the menu (viewers, offline, custom todos).
  final VoidCallback? onAddDetails;

  /// Narrow layouts: short open-label (brand alone / "Search") so the title
  /// keeps the width. The caller pairs this with short label overrides.
  final bool compact;

  /// Per-leg transport-mode picker: when set on a transport row, the leading
  /// kind icon becomes a small menu (fly/drive/train/bus/ferry) and picking a
  /// mode calls back with the canonical value. Null (viewers, offline, slots
  /// whose mode truth is a confirmed segment) keeps the plain icon.
  final ValueChanged<String>? onModeChanged;

  const BookingTodoRow({
    super.key,
    required this.todo,
    required this.onBookedChanged,
    this.onOpen,
    this.openLabelOverride,
    this.onAddDetails,
    this.compact = false,
    this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
      child: Row(
        children: [
          // Fixed-width slot, left-aligned child: with or without the caret,
          // every row's title starts at the same x. Align keeps the
          // constraints loose so the menu's hit target is unchanged.
          SizedBox(
            width: kBookingRowLeadingSlot,
            child: Align(
              alignment: Alignment.centerLeft,
              child: todo.kind == 'transport' && onModeChanged != null
                  ? _ModeMenu(todo: todo, onModeChanged: onModeChanged!)
                  : Icon(_kindIcon(todo),
                      size: 18, color: theme.colorScheme.primary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  todo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: todo.booked ? muted : null,
                    decoration: todo.booked ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (todo.subtitle != null && todo.subtitle!.isNotEmpty)
                  Text(
                    todo.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
          // Compact rows drop the external-link glyph along with the long
          // label: at the 360px overflow floor the row's fixed chrome
          // (leading slot + button + kebab + checkbox) must leave the title
          // a nonzero share.
          if (compact)
            TextButton(
              onPressed: onOpen,
              style: todo.booked
                  ? TextButton.styleFrom(foregroundColor: muted)
                  : null,
              child: Text(_providerOpenLabel(
                  context.l10n, todo, openLabelOverride,
                  compact: true)),
            )
          else
            TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new, size: 18),
              // Trailing glyph: the kebab + checkbox after the button are
              // fixed-width and the cluster packs right, so with the icon
              // after the label every row's open_in_new lands on one column
              // no matter how wide the label is.
              iconAlignment: IconAlignment.end,
              // Booked rows recede: the link stays usable (re-check a price,
              // find the confirmation email's provider) but stops competing
              // with unbooked rows for attention.
              style: todo.booked
                  ? TextButton.styleFrom(foregroundColor: muted)
                  : null,
              label: Text(_providerOpenLabel(
                  context.l10n, todo, openLabelOverride,
                  compact: false)),
            ),
          if (onAddDetails != null)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 18, color: muted),
              tooltip: context.l10n.bookingRowOptions,
              onSelected: (_) => onAddDetails!(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'details',
                  child: Text(context.l10n.bookingRowAddDetails),
                ),
              ],
            ),
          // Last so the fixed-width checkboxes stay flush right and aligned
          // across rows despite varying button-label widths.
          Checkbox(
            value: todo.booked,
            onChanged: (v) => onBookedChanged(v ?? false),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

/// The row's per-leg mode picker: the kind icon plus a dropdown caret, opening
/// a menu of the five leg modes. The current mode (the override when set, else
/// the one the provider implies) is checkmarked; 'rome2rio' alone can't name a
/// ground mode, so such rows simply show no checkmark until overridden.
class _ModeMenu extends StatelessWidget {
  static const _legModes = ['flight', 'car', 'train', 'bus', 'ferry'];

  final BookingTodo todo;
  final ValueChanged<String> onModeChanged;

  const _ModeMenu({required this.todo, required this.onModeChanged});

  String? get _currentMode =>
      todo.mode ??
      switch (todo.provider) {
        'ferry' => 'ferry',
        'google_flights' => 'flight',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _currentMode;
    return PopupMenuButton<String>(
      tooltip: context.l10n.bookingRowModeTooltip,
      onSelected: onModeChanged,
      itemBuilder: (context) => [
        for (final m in _legModes)
          PopupMenuItem(
            value: m,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(transportModeIcon(m),
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(transportModeLabel(context.l10n, m)),
                if (m == current) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check,
                      size: 18, color: theme.colorScheme.primary),
                ],
              ],
            ),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_kindIcon(todo), size: 18, color: theme.colorScheme.primary),
          Icon(Icons.arrow_drop_down,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
