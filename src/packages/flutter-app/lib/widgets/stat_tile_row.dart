import 'package:flutter/material.dart';

/// One stat for a [StatTileRow]: a pre-formatted value over a quiet label.
class StatTileData {
  final String value;
  final String label;

  const StatTileData({required this.value, required this.label});
}

/// A row of equal-width stat tiles — big value over a muted label, centered.
/// The hero-number treatment (vs another pill line) is deliberate: these are
/// lifetime aggregates, not row facts, and the trips list is already
/// pill-dense. Values arrive pre-formatted so the widget stays reusable for
/// any future stat surface; no dividers — spacing separates the tiles.
class StatTileRow extends StatelessWidget {
  final List<StatTileData> tiles;

  const StatTileRow({super.key, required this.tiles});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (final t in tiles)
          Expanded(
            child: Column(
              children: [
                Text(
                  t.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  t.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
