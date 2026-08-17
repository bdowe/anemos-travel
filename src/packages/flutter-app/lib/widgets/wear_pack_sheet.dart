import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/checklist_provider.dart';
import '../theme/spacing.dart';
import '../utils/clothing_recs.dart';
import 'checklist_section.dart';
import 'collapsible_section.dart';
import 'status_pill.dart';
import 'wear_recs.dart';

/// Opens "What to wear & pack" as a modal bottom sheet — the body behind the
/// app-bar luggage icon on the trip detail screen. It replaced the
/// trailing-cluster row, the same move Trip health made (friction-log
/// 2026-08-13).
///
/// [regions] is a snapshot computed by the screen's `_legClothingRecs` at
/// press time, so that derivation stays in exactly one place. The weather
/// providers behind it are settled before the icon renders; the only loss is
/// a report resolving while the sheet is open (reopen refreshes). The
/// checklist is NOT snapshotted: [ChecklistSection] owns the data via
/// [checklistProvider], and the header pill watches the same family key, so
/// edits made inside the sheet update both live.
///
/// Feedback contract: the checklist's snackbars (offline guard, generic
/// error) render BEHIND this sheet's barrier — same accepted debt class as
/// the health sheet's fix snackbars. Primary feedback is the live list
/// itself: a failed toggle visibly doesn't stick.
///
/// No Scaffold inside the sheet, so the framework's Escape→dismiss handling
/// works as-is (a nested Scaffold would swallow DismissIntent — the
/// trip_map_screen trap).
Future<void> showWearPackSheet(
  BuildContext context, {
  required String tripId,
  required List<WearRegionRec> regions,
  required bool canEdit,
  required bool Function() isOffline,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Width cap centers the sheet on desktop, same as the health sheet:
    // guidance rows and checklist entries read stranded at full bleed.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            // Unlike the health sheet, this one hosts a TextField (the
            // add-item row), and showModalBottomSheet applies no keyboard
            // insets itself — pad the scrollable by viewInsets so the field
            // stays above the keyboard (add_to_trip_sheet's recipe).
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: WearPackSheetBody(
              tripId: tripId,
              regions: regions,
              canEdit: canEdit,
              isOffline: isOffline,
            ),
          ),
        ),
      );
    },
  );
}

/// The sheet body: a header line (title · summary · checked-count pill), then
/// the trip-level packing answer, then the per-region guidance behind a
/// "City by city" disclosure, then the live checklist. Public so tests can
/// scope finders to the sheet.
///
/// Leading with the summary is the 2026-08-17 amendment: on an eight-city trip
/// the per-region rows opened as sixteen lines of prose and left the reader to
/// work out the union themselves. [packEssentials] does that union from the
/// same groups [WearRecsList] renders, so the detail collapses losslessly.
class WearPackSheetBody extends ConsumerStatefulWidget {
  final String tripId;
  final List<WearRegionRec> regions;
  final bool canEdit;

  /// Live read, not a captured bool: the sheet route never rebuilds on the
  /// screen's connectivity setState.
  final bool Function() isOffline;

  const WearPackSheetBody({
    super.key,
    required this.tripId,
    required this.regions,
    required this.canEdit,
    required this.isOffline,
  });

  @override
  ConsumerState<WearPackSheetBody> createState() => _WearPackSheetBodyState();
}

class _WearPackSheetBodyState extends ConsumerState<WearPackSheetBody> {
  /// [CollapsibleSection] requires the parent to own this. Route-scoped here —
  /// the sheet body never reparents, and reopening the sheet is meant to start
  /// closed again, so there is nothing to lift higher.
  bool _cityDetailOpen = false;

  @override
  Widget build(BuildContext context) {
    final tripId = widget.tripId;
    final regions = widget.regions;
    final canEdit = widget.canEdit;
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final items = ref.watch(checklistProvider(tripId)).valueOrNull;
    final showChecklist = items != null && !(items.isEmpty && !canEdit);
    // The app-bar icon's gate and this body can disagree for one frame while
    // a provider flips; render nothing rather than dereference a state the
    // gate no longer justifies.
    if (regions.isEmpty && !showChecklist) return const SizedBox.shrink();
    final checked = items?.where((i) => i.checked).length ?? 0;
    // Header one-liner: the cross-region temperature envelope plus the rain
    // signal — kind-neutral by design, the "typical" qualifier lives in the
    // single footnote below the summary. Spaced dash like the date ranges
    // ("Sep 15 – Sep 20"), so a negative low never collides with it
    // ("-6° – 2°"). Without weather, the checked-count summary stands in.
    final String summary;
    if (regions.isNotEmpty) {
      final s = clothingSummary([for (final r in regions) r.rec]);
      final range = '${s.loC}° – ${s.hiC}°';
      summary = s.rainLikely ? '$range · ${l10n.wearSummaryRain}' : range;
    } else {
      summary = l10n.checklistSummary(checked, items!.length);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.wearSectionTitle,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            // With recs in the summary slot, the checked count stays
            // glanceable via the pill (the old collapsed row's rule).
            if (regions.isNotEmpty && items != null && items.isNotEmpty)
              StatusPill.custom(
                label: '$checked/${items.length}',
                background: theme.colorScheme.surfaceContainerHighest,
                foreground: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (regions.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(
              l10n.wearPackTitle,
              // Muted labelLarge section label — the city_events_sheet group
              // header treatment, which is what keeps this read-only block
              // visibly distinct from the editable checklist below it.
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          PackEssentialsList(regions: regions),
          // Outside the disclosure on purpose: this qualifies the header's
          // temperature envelope as much as the rows, so it can't hide behind
          // a tap (specs/what-to-wear, the "framed as typical" story).
          if (anyHistorical(regions))
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                // Italic+muted only — the _weatherChip qualifier treatment.
                l10n.wearHistoricalFootnote,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          // One displayed group means the detail adds only its dates — the
          // envelope is already in the header — so a disclosure would be a tap
          // charged for nothing. Render it inline instead.
          //
          // Grouping is recomputed rather than threaded through: it is pure
          // and runs over a handful of legs, and passing groups down would
          // cost [WearRecsList] and [PackEssentialsList] the regions-in
          // contract that keeps them display-only.
          if (groupWearRegions(regions).length < 2)
            WearRecsList(regions: regions)
          else
            CollapsibleSection(
              title: l10n.wearByCityTitle,
              icon: Icons.location_on_outlined,
              expanded: _cityDetailOpen,
              onToggle: () =>
                  setState(() => _cityDetailOpen = !_cityDetailOpen),
              child: WearRecsList(regions: regions),
            ),
        ],
        if (regions.isNotEmpty && showChecklist) const Divider(height: 24),
        ChecklistSection(
          tripId: tripId,
          canEdit: canEdit,
          isOffline: widget.isOffline,
          showHeader: false,
        ),
      ],
    );
  }
}
