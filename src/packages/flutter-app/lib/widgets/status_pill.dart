import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';

/// A filled tonal pill for a trip's status (draft / planned, rendered through
/// AppLocalizations). Reads at a glance and stays colorblind-safe by carrying
/// its label, not just a colored dot. Shared by the trips list and the
/// trip-detail header.
///
/// [StatusPill.custom] renders the same pill chrome with an explicit label and
/// colors (no leading icon, smaller type) for non-trip states — e.g. the price
/// alerts screen.
class StatusPill extends StatelessWidget {
  final String status;

  /// Optional trailing widget (e.g. a dropdown arrow when the pill doubles as a
  /// status picker trigger). Tinted to match the label.
  final Widget? trailing;

  final String? _label;
  final Color? _background;
  final Color? _foreground;

  const StatusPill({super.key, required this.status, this.trailing})
      : _label = null,
        _background = null,
        _foreground = null;

  const StatusPill.custom({
    super.key,
    required String label,
    required Color background,
    required Color foreground,
  })  : status = '',
        trailing = null,
        _label = label,
        _background = background,
        _foreground = foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String label;
    final Color bg;
    final Color fg;
    IconData? icon;
    final TextStyle? style;
    if (_label != null) {
      label = _label;
      bg = _background!;
      fg = _foreground!;
      style = theme.textTheme.labelSmall;
    } else {
      final isPlanned = status == 'planned';
      // Canonical API statuses map to localized copy (the same mapping the
      // trip-detail status menu uses); anything unexpected falls back to
      // title-case rather than rendering blank.
      label = switch (status) {
        '' || 'draft' => context.l10n.tripStatusDraft,
        'planned' => context.l10n.tripStatusPlanned,
        _ => '${status[0].toUpperCase()}${status.substring(1)}',
      };

      // Planned reads as a positive, completed state (green); anything else is
      // a neutral surface tone so it doesn't compete for attention.
      bg = isPlanned
          ? AppColors.successContainer
          : theme.colorScheme.surfaceContainerHighest;
      fg = isPlanned
          ? AppColors.onSuccessContainer
          : theme.colorScheme.onSurfaceVariant;
      icon = isPlanned ? Icons.check_circle : Icons.edit_note;
      style = theme.textTheme.labelMedium;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: AppSpacing.xs),
          ],
          // Flexible + ellipsis: a long custom label (e.g. the Spanish
          // flight-savings pill at 360px) truncates instead of overflowing
          // the pill's Row.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null)
            IconTheme.merge(
              data: IconThemeData(color: fg, size: 18),
              child: trailing!,
            ),
        ],
      ),
    );
  }
}
