import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../theme/spacing.dart';

/// A quiet one-line summary of a result set the agent found (flights, events,
/// local picks, ferries) — replaces inline card stacks in the chat. The full
/// results live on the trip detail screen; when [onTap] is set the chip shows
/// a "View in trip" affordance and links there.
class ResultSummaryChip extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String label;
  final VoidCallback? onTap;

  const ResultSummaryChip({
    super.key,
    required this.icon,
    required this.accent,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Material(
          color: accent.withValues(alpha: 0.08),
          borderRadius: AppRadius.lgAll,
          child: InkWell(
            onTap: onTap,
            borderRadius: AppRadius.lgAll,
            // When tappable it's a real navigation control: grow the hit box
            // to the touch floor (the Row centers within the constraint).
            child: ConstrainedBox(
              constraints: onTap != null
                  ? const BoxConstraints(minHeight: kMinTouchTarget)
                  : const BoxConstraints(),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: accent),
                    const SizedBox(width: AppSpacing.sm),
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (onTap != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        context.l10n.resultChipViewInTrip,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 16, color: accent),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
