import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/trip_finding.dart';
import '../theme/spacing.dart';
import 'section_header.dart';
import 'status_pill.dart';

/// Opens the "Plan progress" sheet: the planning ladder behind the Next Step
/// card's "N of 6" counter (specs/next-step-cta). Tapping the counter is what
/// leads here — a number nobody can expand is a dead end, and this is the one
/// surface that says what the six steps are.
///
/// Purely informational: no fixes, no network, no provider. The [progress] and
/// [currentStep] are the payload the card is already rendering, snapshotted at
/// press time, so the sheet also opens offline (unlike the card's actions,
/// which mutate or fetch).
///
/// No Scaffold inside the sheet, so the framework's Escape→dismiss handling
/// works as-is (a nested Scaffold would swallow DismissIntent — the
/// trip_map_screen trap).
Future<void> showPlanProgressSheet(
  BuildContext context, {
  required PlanProgress progress,
  NextStep? currentStep,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Width cap centers the sheet on desktop, same as the health/events
    // sheets: a six-row list reads stranded at full bleed.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      final screenHeight = MediaQuery.of(sheetContext).size.height;
      return SafeArea(
        child: ConstrainedBox(
          // A FLOOR as well as a ceiling, unlike the sibling sheets. This is
          // the only one whose content has a fixed, short length — six rows
          // never grow — so on a tall window it hugged the bottom edge and
          // read as a footer rather than a panel (Brian, 2026-08-14). The
          // slack falls below the last rung; rows stay top-aligned.
          constraints: BoxConstraints(
            minHeight: screenHeight * 0.62,
            maxHeight: screenHeight * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
            child: PlanProgressSheetBody(
              progress: progress,
              currentStep: currentStep,
            ),
          ),
        ),
      );
    },
  );
}

/// The sheet body: the ladder, in server order, with the current rung carrying
/// the step the card is showing. Pure and provider-free — the same doctrine as
/// [NextStepCard], so it unit-tests without a harness. Public so tests (and a
/// future non-modal host) can render it directly.
class PlanProgressSheetBody extends StatelessWidget {
  final PlanProgress progress;

  /// The step the card is showing, rendered under the current rung so "step 3"
  /// and "Book your flight to Prague" are visibly the same thing. Null (or the
  /// all_set terminal step) simply omits that block.
  final NextStep? currentStep;

  const PlanProgressSheetBody({
    super.key,
    required this.progress,
    this.currentStep,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final phases = progress.phases;
    if (phases.isEmpty) return const SizedBox.shrink();

    // Same clamp the card's eyebrow uses, so the pill and the counter that
    // opened this sheet always read the same. all_set (done == total) lands on
    // "6 of 6" rather than an impossible 7th step.
    final total = progress.total > 0 ? progress.total : phases.length;
    final current = (progress.done + 1).clamp(1, total);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionHeader(
          title: l10n.planProgressTitle,
          // Scheme colors, not the card's brand tint: this pill sits on the
          // plain sheet surface (the card paints its own light background), so
          // it has to follow the theme into dark mode.
          action: StatusPill.custom(
            label: l10n.nextStepProgress(current, total),
            background: theme.colorScheme.primaryContainer,
            foreground: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        // Why a later rung is not a failure: prefix progress can only speak
        // for the steps up to the current one, so rows below it are "later",
        // never "incomplete".
        Text(
          l10n.planProgressHint,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < phases.length; i++)
          _PhaseRow(
            key: ValueKey('plan-phase-${phases[i].id}'),
            phase: phases[i],
            state: i < progress.done
                ? _PhaseState.done
                : i == progress.done
                    ? _PhaseState.current
                    : _PhaseState.later,
            step: i == progress.done ? currentStep : null,
          ),
      ],
    );
  }
}

enum _PhaseState { done, current, later }

/// One ladder rung. The leading mark is the only state carrier — no per-phase
/// icon, which would mean re-encoding the server's ladder vocabulary here.
class _PhaseRow extends StatelessWidget {
  final PlanPhase phase;
  final _PhaseState state;

  /// The card's step, rendered under the current rung only.
  final NextStep? step;

  const _PhaseRow({
    super.key,
    required this.phase,
    required this.state,
    this.step,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    // Marks are scheme-colored (the sheet has no brand-tinted background to
    // sit on, so the fixed teal ramp would vanish in dark mode) and the state
    // rides the GLYPH, not the hue: filled check behind you, target ring where
    // you are, empty ring ahead.
    final (icon, color, stateLabel) = switch (state) {
      _PhaseState.done => (
          Icons.check_circle,
          theme.colorScheme.primary,
          l10n.planProgressStateDone,
        ),
      _PhaseState.current => (
          Icons.radio_button_checked,
          theme.colorScheme.primary,
          l10n.planProgressStateCurrent,
        ),
      _PhaseState.later => (
          Icons.radio_button_unchecked,
          theme.colorScheme.outline,
          l10n.planProgressStateLater,
        ),
    };

    final s = step;
    final showStep = s != null && s.kind != 'all_set';
    final detail = s?.detail;
    // Rungs whose step title IS the rung label (the schedule rung, when the
    // driver is empty days) would otherwise print "Plan your days" twice, in
    // two colors. The label already said it; only the detail adds anything.
    final showTitle = showStep && s.title != phase.label;

    // The rung's own tally ("4 of 11"), for rungs that have one. It is the
    // only number that moves while a many-city trip sits on "3 of 6" —
    // eleven booking slots close one at a time under a single rung. The rung
    // label supplies the noun, so this reuses the bare "{n} of {total}" the
    // eyebrow counter already speaks.
    final tally = phase.progress;
    final tallyLabel =
        tally == null ? null : l10n.nextStepProgress(tally.done, tally.total);

    return Semantics(
      label: [phase.label, stateLabel, if (tallyLabel != null) tallyLabel]
          .join(', '),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    phase.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: state == _PhaseState.current
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: state == _PhaseState.later
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  if (showStep) ...[
                    const SizedBox(height: AppSpacing.xs),
                    if (showTitle)
                      Text(
                        s.title,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.primary),
                      ),
                    if (detail != null && detail.isNotEmpty)
                      Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            if (tallyLabel != null) ...[
              const SizedBox(width: AppSpacing.sm),
              // Trailing and muted: it answers "how much is left here?", it is
              // not the rung's headline. Excluded from semantics — the row's
              // own label already reads it out in context.
              ExcludeSemantics(
                child: Text(
                  tallyLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
