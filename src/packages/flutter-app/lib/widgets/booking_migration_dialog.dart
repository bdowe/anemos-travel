import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';

/// What the traveler decided about a booked checklist row the route left
/// behind. Null (the dialog's return, not a value) means no choice was made.
enum BookingMigrationChoice { move, keep, remove }

/// The migrate_booking finding's three-way choice
/// (stale-transport-orphans ticket 2). A booked transport todo whose
/// endpoints are no longer consecutive stops is the traveler's call, never
/// the app's — the production trip that started this arc ended with the
/// booked flag on endpoints the traveler does not hold precisely because the
/// system moved on without asking. So the finding presents a choice, not a
/// notice:
///
/// - **move** — re-point the SAME row at the replacement leg ([moveLabel]
///   names it, e.g. "Move booking to Gothenburg → Naples (Sep 13)"); the
///   booked tick, saved shortlist and expense links carry over.
/// - **keep** — leave the row as an other-booking; it still names the
///   reservation the traveler actually holds.
/// - **remove** — delete the row outright.
///
/// The screen owns the services and applies the choice; this dialog only
/// asks the question. [message] is the finding's own server-localized text,
/// which names the stale pair.
Future<BookingMigrationChoice?> showBookingMigrationDialog(
  BuildContext context, {
  required String message,
  required String moveLabel,
}) {
  return showDialog<BookingMigrationChoice>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final l10n = context.l10n;
      return AlertDialog(
        title: Text(l10n.reviewMigrationTitle),
        // Full-width stacked actions rather than the actions row: the move
        // label names both cities and a date, far past what a button row
        // holds without truncating the very words the choice is about.
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, BookingMigrationChoice.move),
              child: Text(moveLabel),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, BookingMigrationChoice.keep),
              child: Text(l10n.reviewMigrationKeep),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, BookingMigrationChoice.remove),
              child: Text(
                l10n.bookingCardRemove,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
      );
    },
  );
}
