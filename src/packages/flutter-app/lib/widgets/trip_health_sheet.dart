import 'package:flutter/material.dart';

import '../models/trip_finding.dart';
import '../theme/spacing.dart';
import 'trip_review_section.dart';

/// Opens the Trip health findings list as a modal bottom sheet — the body
/// behind the app-bar health icon on the trip detail screen.
///
/// Deliberately pushed on the nearest (tab) navigator, NOT the root one:
/// [onApplyFix] flows open their own sheets via the screen's context on the
/// same tab navigator, so they must be able to stack ABOVE this sheet and
/// return to it on close (fix dialogs use root-navigator dialogs, which layer
/// above either way).
///
/// Feedback contract: the screen's snackbars render BEHIND this sheet's
/// barrier. Success feedback is the finding dropping off the list (the
/// section watches the provider the screen invalidates after every fix); a
/// FAILED fix throws out of `_applyFix`, and the wrapper below closes the
/// sheet so the screen's error snackbar is seen instead of a silent no-op.
///
/// No Scaffold inside the sheet, so the framework's Escape→dismiss handling
/// works as-is (a nested Scaffold would swallow DismissIntent — the
/// trip_map_screen trap).
Future<void> showTripHealthSheet(
  BuildContext context, {
  required String tripId,
  required bool Function() isOffline,
  void Function(int day)? onScrollToDay,
  int? Function(String itemId)? dayForItem,
  Future<void> Function(TripFinding finding)? onApplyFix,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Width cap centers the sheet on desktop: findings are a narrow task
    // list, like the add-to-trip picker — full-bleed rows read stranded.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      // Single-fire pop: two callbacks landing together (two rows tapped in
      // the same frame, or a callback racing a drag-dismiss) must not pop
      // twice — the second pop would eject the trip screen itself off the
      // tab navigator this sheet shares with it.
      void popSheet() {
        final route = ModalRoute.of(sheetContext);
        if (route != null && route.isCurrent) {
          Navigator.of(sheetContext).pop();
        }
      }

      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
            child: TripReviewSection(
              tripId: tripId,
              isOffline: isOffline,
              // Scroll targets live on the screen beneath: close the sheet
              // first, then scroll. Safe without a post-frame wait — the
              // screen stays mounted and laid out under the modal route.
              onScrollToDay: onScrollToDay == null
                  ? null
                  : (day) {
                      popSheet();
                      onScrollToDay(day);
                    },
              dayForItem: dayForItem,
              onApplyFix: onApplyFix == null
                  ? null
                  : (finding) async {
                      try {
                        await onApplyFix(finding);
                      } catch (_) {
                        // The screen already showed its error snackbar —
                        // behind this sheet. Close so the failure is seen.
                        popSheet();
                      }
                    },
            ),
          ),
        ),
      );
    },
  );
}
