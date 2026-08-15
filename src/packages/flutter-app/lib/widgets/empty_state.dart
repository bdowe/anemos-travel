import 'package:flutter/material.dart';
import '../theme/spacing.dart';

/// A centered icon + title + message, with optional actions. One implementation
/// for every "nothing here yet", error, or "no results" state so they read the
/// same across the app instead of some being styled and others plain text.
class EmptyState extends StatelessWidget {
  /// Null on surfaces that carry their own visual anchor — the agent chat's
  /// empty state leads with destination photos, above which a generic glyph
  /// is just weight.
  final IconData? icon;

  final String title;
  final String? message;

  /// Rich content between the message and [actions]. Anything much taller than
  /// a button belongs here rather than in [actions], where the Wrap would
  /// centre it against the chips and read as broken alignment.
  final Widget? content;

  /// Optional buttons (e.g. a Retry or a CTA) rendered below the message.
  final List<Widget> actions;

  /// Tints the icon. Defaults to a muted primary.
  final Color? iconColor;

  /// Tighter metrics (smaller icon and type, less padding) for short
  /// containers — e.g. the 240px trip-map header, where the default 64px icon
  /// plus a title and a button would overflow.
  final bool compact;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.content,
    this.actions = const [],
    this.iconColor,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      // Overflow floor for short fixed-height containers (inline map preview,
      // large accessibility text scales, longer locales): when the content
      // fits, the scroll view shrink-wraps and rendering is identical; when
      // it doesn't, the block clips/scrolls instead of throwing a RenderFlex
      // overflow.
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(compact ? AppSpacing.lg : AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: compact ? 32 : 64,
                  color: iconColor ??
                      theme.colorScheme.primary.withValues(alpha: 0.5),
                ),
                SizedBox(height: compact ? AppSpacing.sm : AppSpacing.lg),
              ],
              Text(
                title,
                style: (compact
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleLarge)
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              if (message != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: (compact
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (content != null) ...[
                SizedBox(height: compact ? AppSpacing.md : AppSpacing.xl),
                content!,
              ],
              if (actions.isNotEmpty) ...[
                SizedBox(height: compact ? AppSpacing.md : AppSpacing.xl),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  alignment: WrapAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
