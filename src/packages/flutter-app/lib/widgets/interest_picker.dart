import 'package:flutter/material.dart';
import '../constants/interest_bank.dart';
import '../l10n/l10n.dart';
import '../theme/spacing.dart';

/// Interests picker: the suggested bank plus any custom selections as
/// FilterChips, with an "add an interest" free-text row underneath.
///
/// Matching is case-insensitive to mirror the server's dedupe
/// (normalizeInterests keys on lowercase): a saved 'Live Music' lights up
/// the 'live music' bank chip instead of rendering a duplicate, and
/// deselecting a chip removes every case variant from the selection.
class InterestPicker extends StatefulWidget {
  /// Current selection, exactly as it will be persisted.
  final Set<String> selected;

  /// Called with the complete new selection after any toggle or custom add.
  final ValueChanged<Set<String>> onChanged;

  const InterestPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<InterestPicker> createState() => _InterestPickerState();
}

class _InterestPickerState extends State<InterestPicker> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isSelected(String value) {
    final lower = value.toLowerCase();
    return widget.selected.any((s) => s.toLowerCase() == lower);
  }

  void _toggle(String value, bool select) {
    if (select) {
      widget.onChanged({...widget.selected, value});
    } else {
      final lower = value.toLowerCase();
      widget.onChanged(
        widget.selected.where((s) => s.toLowerCase() != lower).toSet(),
      );
    }
  }

  void _addInterest() {
    final t = _controller.text.trim();
    if (t.isEmpty) return;
    // Typing a bank value (any casing) selects the canonical chip instead of
    // adding a raw duplicate; an already-selected value is a no-op.
    final lower = t.toLowerCase();
    final canonical = suggestedInterests.firstWhere(
      (v) => v.toLowerCase() == lower,
      orElse: () => t,
    );
    if (!_isSelected(canonical)) {
      widget.onChanged({...widget.selected, canonical});
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    // Chips = the suggested bank in curated order, then any custom selections
    // whose lowercase doesn't collide with a bank value.
    final lowerBank =
        suggestedInterests.map((v) => v.toLowerCase()).toSet();
    final chipValues = [
      ...suggestedInterests,
      ...widget.selected.where((s) => !lowerBank.contains(s.toLowerCase())),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: chipValues.map((value) {
            return FilterChip(
              label: Text(interestLabel(l10n, value)),
              selected: _isSelected(value),
              onSelected: (sel) => _toggle(value, sel),
            );
          }).toList(),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(hintText: l10n.prefsAddInterest),
                onSubmitted: (_) => _addInterest(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: l10n.prefsAddInterest,
              onPressed: _addInterest,
            ),
          ],
        ),
      ],
    );
  }
}
