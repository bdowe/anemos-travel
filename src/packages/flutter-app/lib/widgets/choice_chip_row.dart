import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// A single-select row of [ChoiceChip]s. Tapping the selected chip again
/// clears the selection (passes null).
class ChoiceChipRow extends StatelessWidget {
  final List<String> options;
  final String? selected;
  final ValueChanged<String?> onSelected;

  /// Maps an option to its display text. [options] are canonical API values
  /// (`budget`/`mid`/`luxury`), so localized screens pass a translator here
  /// while the values sent to the server stay unchanged. Defaults to showing
  /// the value itself (specs/i18n-spanish).
  final String Function(String value)? labelBuilder;

  const ChoiceChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.labelBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      // Long localized labels (es) wrap onto extra runs; keep them breathing.
      runSpacing: AppSpacing.xs,
      children: options.map((o) {
        return ChoiceChip(
          label: Text(labelBuilder?.call(o) ?? o),
          selected: selected == o,
          onSelected: (sel) => onSelected(sel ? o : null),
        );
      }).toList(),
    );
  }
}
