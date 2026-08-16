import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';

/// The trip's name and description as the traveler just typed them. Popping null
/// means they cancelled.
///
/// [description] is empty — never null — when they cleared it: an empty
/// description is a real instruction ("remove this"), and the API sends `""` for
/// exactly that reason. Conflating it with "not edited" is what would make the
/// clear silently do nothing.
class TripDetailsEdit {
  final String title;
  final String description;

  const TripDetailsEdit({required this.title, required this.description});
}

/// THE editor for a trip's name and description (specs/trip-description) —
/// one dialog, because they are one thought: a traveler fixing a blurb the
/// planner wrote is usually fixing the name in the same breath, and two
/// affordances would mean two requests for one edit.
///
/// Returns a [TripDetailsEdit] or null; the CALLER owns the save, like
/// [TripAirportsSheet] and unlike showBudgetTargetDialog — the trip screen holds
/// the trip in local State and re-seeds it from the server's response, so the
/// write has to stay there.
Future<TripDetailsEdit?> showTripDetailsDialog(
  BuildContext context, {
  required String title,
  String? description,
}) {
  return showDialog<TripDetailsEdit>(
    context: context,
    builder: (_) => _TripDetailsDialog(title: title, description: description),
  );
}

/// The trip page shows the description clamped to two lines, so this is the cap
/// the field advertises. Mirrors maxSummaryLen on the server, which rejects
/// anything longer with a 400 — the counter is here so a traveler learns the
/// limit while typing rather than from a failed save.
const int kTripDescriptionMaxLength = 2000;

class _TripDetailsDialog extends StatefulWidget {
  final String title;
  final String? description;

  const _TripDetailsDialog({required this.title, this.description});

  @override
  State<_TripDetailsDialog> createState() => _TripDetailsDialogState();
}

class _TripDetailsDialogState extends State<_TripDetailsDialog> {
  late final TextEditingController _title =
      TextEditingController(text: widget.title);
  late final TextEditingController _description =
      TextEditingController(text: widget.description ?? '');

  /// Save stays disabled on an empty name: the server rejects a blank title, and
  /// a button that produces a 400 is worse than one that says why it can't.
  /// The DESCRIPTION may be emptied freely — that is the clear.
  bool _nameIsEmpty = false;

  @override
  void initState() {
    super.initState();
    _nameIsEmpty = _title.text.trim().isEmpty;
    _title.addListener(() {
      final empty = _title.text.trim().isEmpty;
      if (empty != _nameIsEmpty) setState(() => _nameIsEmpty = empty);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(
      context,
      TripDetailsEdit(
        title: _title.text.trim(),
        description: _description.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.tripEditDetails),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.tripDetailsNameLabel,
                border: const OutlineInputBorder(),
                errorText: _nameIsEmpty ? l10n.tripDetailsNameRequired : null,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _description,
              minLines: 3,
              maxLines: 6,
              maxLength: kTripDescriptionMaxLength,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: l10n.tripDetailsDescriptionLabel,
                hintText: l10n.tripDetailsDescriptionHint,
                helperText: l10n.tripDetailsDescriptionHelp,
                helperMaxLines: 2,
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _nameIsEmpty ? null : _save,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
