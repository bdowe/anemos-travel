import 'package:flutter/material.dart';
import '../theme/spacing.dart';

/// A filled tonal pill with an explicit label and colors — the shared chrome
/// for small state chips (Live, Past-trips count, Today, packing and review
/// counts, price alerts, …). Reads at a glance and stays colorblind-safe by
/// carrying its label, not just a colored dot.
///
/// The trip draft/planned variant this widget originally rendered is retired
/// (specs/retire-trip-status); only the explicit-label constructor remains —
/// pill chrome with an explicit label and colors (no leading icon, smaller
/// type) for non-trip states.
class StatusPill extends StatelessWidget {
  final String _label;
  final Color _background;
  final Color _foreground;

  const StatusPill.custom({
    super.key,
    required String label,
    required Color background,
    required Color foreground,
  })  : _label = label,
        _background = background,
        _foreground = foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: _background,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Flexible + ellipsis: a long custom label (e.g. the Spanish
          // flight-savings pill at 360px) truncates instead of overflowing
          // the pill's Row.
          Flexible(
            child: Text(
              _label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: _foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
