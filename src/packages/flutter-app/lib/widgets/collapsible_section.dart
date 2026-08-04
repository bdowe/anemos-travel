import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// A one-line section row (icon · title · summary · pill · chevron) that
/// expands in place. The trip detail page renders its trailing sections
/// (Trip health, Packing, Budget) behind these rows, closed by default, so
/// the page ends in a quiet index instead of three full sections.
///
/// The parent owns [expanded]: trip detail keeps the set of open sections in
/// screen state (like its city/day collapse sets), so expansion survives
/// silent refreshes and the offline-banner reparent. [child] is built only
/// while expanded — collapsed rows must get their [summary]/[pill] data from
/// providers watched by the PARENT, never from the child's own watches.
///
/// No AnimatedSize on expand: the row sits in a scroll view whose today-mode
/// offset math assumes settled extents, so the child appears in a single
/// frame.
class CollapsibleSection extends StatelessWidget {
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  /// Leading icon for the collapsed row; muted so the title keeps the weight.
  final IconData? icon;

  /// One-line collapsed summary ("2 of 9 booked", "$120 spent · no target").
  final String? summary;

  /// Optional trailing pill (counts / severity), e.g. a [StatusPill.custom].
  final Widget? pill;

  const CollapsibleSection({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.icon,
    this.summary,
    this.pill,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(
        onTap: onToggle,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTouchTarget),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.sm),
              ],
              Text(
                title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: summary == null
                    ? const SizedBox.shrink()
                    : Text(
                        summary!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
              ),
              if (pill != null) ...[
                pill!,
                const SizedBox(width: AppSpacing.sm),
              ],
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
    if (!expanded) return header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: child,
        ),
      ],
    );
  }
}
