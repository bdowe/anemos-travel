import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// Display-only icon + label fact, styled as a tonal pill so it pairs with
/// the [StatusPill] beside it and matches the trip-detail header's date chip.
/// The trips list uses it for a card's date range, duration, and city count;
/// it carries context, not state — state chips are StatusPill's job.
class MetaChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const MetaChip({super.key, required this.label, this.icon = Icons.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
