import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// One stat for a [StatTileRow]: a pre-formatted value and its quiet label.
class StatTileData {
  final String value;
  final String label;

  const StatTileData({required this.value, required this.label});
}

/// A stat line — `6 trips · 166 travel days · 20 cities` — where the number
/// carries Inter's weight and the label stays muted beside it.
///
/// It used to be a row of equal-width tiles, each a big value stacked over a
/// small label. That is the brand doc's named anti-pattern (the hero-metric
/// template) and it read as a dashboard panel bolted under the footprint map:
/// three centered columns of chrome for what is, in the end, a caption. The
/// line form applies the house rule instead — below the headline, hierarchy is
/// **weight, not size** — so the same facts read as one sentence of numbers
/// under an image, the way a plate caption reads in a journal.
///
/// The widget still formats and pluralizes NOTHING: values arrive
/// pre-formatted and the l10n plural is resolved at the call site, so a label
/// is printed exactly as handed over. It stays a [Wrap], not a [Row]: the es
/// labels run long, and at 300px three stats have to fall onto a second line
/// rather than ellipsize into uselessness.
class StatTileRow extends StatelessWidget {
  final List<StatTileData> tiles;

  /// Value color; defaults to the surface ink. Named rather than assumed so a
  /// caller placing this on a non-surface field states it.
  final Color? valueColor;

  /// Label (and separator) color; defaults to the muted surface ink.
  final Color? labelColor;

  const StatTileRow({
    super.key,
    required this.tiles,
    this.valueColor,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = labelColor ?? theme.colorScheme.onSurfaceVariant;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          // A separator between stats, never leading one: the dot is its own
          // widget so each value and label stays an addressable Text (the
          // callers' tests ask for them by exact string).
          if (i > 0)
            Text(
              '·',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          _Stat(
            data: tiles[i],
            valueColor: valueColor ?? theme.colorScheme.onSurface,
            labelColor: muted,
          ),
        ],
      ],
    );
  }
}

/// One `value label` pair, baseline-ish aligned. The label is the part that
/// gives — a stat whose label cannot fit its run truncates rather than
/// striping the card with a RenderFlex overflow (the StatusPill treatment).
class _Stat extends StatelessWidget {
  final StatTileData data;
  final Color valueColor;
  final Color labelColor;

  const _Stat({
    required this.data,
    required this.valueColor,
    required this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          data.value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: valueColor,
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            data.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: labelColor),
          ),
        ),
      ],
    );
  }
}
