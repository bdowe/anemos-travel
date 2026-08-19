// The trip detail header stack (specs/trip-detail-extract): the title/meta
// block, the Next Step card, and the Continue-chat card, lifted verbatim out
// of trip_detail_screen.dart so wave 2 can redesign the header shell without
// the god-screen. Screen state arrives as constructor params; actions are
// callbacks into the screen. Pure move — zero visual, zero behavior change.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../models/trip.dart';
import '../../models/trip_finding.dart';
import '../../providers/trip_review_provider.dart';
import '../../theme/app_typography.dart';
import '../../theme/spacing.dart';
import '../../utils/trip_format.dart';
import '../next_step_card.dart';
import '../offline_banner.dart';
import '../plan_progress_sheet.dart';

/// The header stack above the map band: title + meta chips + context line +
/// clamped overview, then the Next Step and Continue-chat cards. Renders as
/// one stretched column, exactly the children the screen's header sliver
/// used to compose inline.
class TripHeaderCard extends ConsumerStatefulWidget {
  final Trip trip;
  final bool narrow;
  final bool isOffline;
  final bool readOnly;
  final bool panelOpen;
  final String displayTitle;
  final String? overview;
  final VoidCallback onEditDetails;
  final VoidCallback onEditDates;
  final VoidCallback onRefine;
  final Future<void> Function(NextStep step) onNextStepAction;
  final VoidCallback onOpenHealthSheet;
  final bool Function(NextStep step) transportHandsOff;
  final VoidCallback onOpenChat;
  final VoidCallback onNewChat;

  const TripHeaderCard({
    super.key,
    required this.trip,
    required this.narrow,
    required this.isOffline,
    required this.readOnly,
    required this.panelOpen,
    required this.displayTitle,
    required this.overview,
    required this.onEditDetails,
    required this.onEditDates,
    required this.onRefine,
    required this.onNextStepAction,
    required this.onOpenHealthSheet,
    required this.transportHandsOff,
    required this.onOpenChat,
    required this.onNewChat,
  });

  @override
  ConsumerState<TripHeaderCard> createState() => _TripHeaderCardState();
}

class _TripHeaderCardState extends ConsumerState<TripHeaderCard> {
  // Next-step celebration state (session-scoped) — moved with the card from
  // the screen's State; only this area ever read or wrote it.
  bool _hadNextStep = false;
  bool _allSetDismissed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerCard(theme),
        _nextStepArea(),
        _continueChatRow(theme, l10n),
      ],
    );
  }

  Widget _headerCard(ThemeData theme) {
    final trip = widget.trip;
    final l10n = context.l10n;
    final overview = widget.overview;
    final hasDates = trip.startDate != null && trip.endDate != null;
    // Deliberately card-less: the app bar already carries the title, so this
    // block is a compact anchor (rename affordance + meta chips + context
    // line + clamped overview), not a hero panel.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                widget.displayTitle,
                // Same string as the app bar directly above, so same face —
                // but keeping titleLarge's size, because this block is a
                // compact anchor and headlineSmall would inflate it into the
                // hero panel the comment above rules out.
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFamily: AppFonts.display,
                  fontWeight: FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trip.canEdit)
              IconButton(
                icon: const Icon(Icons.edit, size: 20),
                tooltip: l10n.tripEditDetails,
                onPressed: widget.isOffline ? null : widget.onEditDetails,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ActionChip(
              avatar: const Icon(Icons.event, size: 16),
              // Humanized short range ("Jul 20 – Jul 27") at every width, and
              // localized with it (tripDateRange goes through the app locale,
              // so Spanish reads "20 jul – 27 jul"). Narrow got this first,
              // because the raw ISO pair is ~200px and forced the meta row to
              // wrap; wide simply kept the machine form it started with, which
              // left the SAME trip reading "2026-07-21 → 2026-07-22" on desktop
              // and "Jul 21 – Jul 22" on a phone. Width is not a reason to
              // show a different date format — and the layout that has more
              // room was the one showing the denser string.
              //
              // The ISO pair survives only as the unparseable-date fallback:
              // tripDateRange returns null there, and echoing back whatever is
              // stored beats an empty chip on a trip whose dates are the thing
              // you came to fix.
              label: Text(hasDates
                  ? (tripDateRange(trip.startDate, trip.endDate) ??
                      '${trip.startDate} → ${trip.endDate}')
                  : l10n.tripAddDates),
              onPressed: (widget.isOffline || !trip.canEdit) ? null : widget.onEditDates,
            ),
            // The draft/planned status pill is gone with the status concept
            // itself (specs/retire-trip-status) — dates carry the state.
            // The trip-wide travel-mode pill is gone: transport mode is
            // per-leg now, picked directly on each transport row (the
            // _ModeMenu in BookingTodoRow). trips.travel_mode remains the
            // AI-facing trip default behind _groundModeOf.
            // Refine entry, demoted from a full-width banner to a peer of the
            // meta chips. Same canEdit gate as before, so editor
            // collaborators keep their spec-mandated entry point
            // (specs/collaborator-refine); the per-city/day sparkles and the
            // chat FAB are unchanged. On narrow this moves to the app bar.
            if (trip.canEdit && !widget.narrow)
              FilledButton.tonalIcon(
                // Chat/refine needs the network — disabled while offline.
                onPressed: widget.isOffline
                    ? null
                    : widget.onRefine,
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text(l10n.tripRefineWithAI),
              ),
          ],
        ),
        // Muted context line: collaborator standing and/or "Updated by
        // Maria · 2m ago" (the server omits self-attribution). Either part
        // can stand alone.
        if (!trip.isOwner || trip.updatedByName != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!trip.isOwner)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        trip.canEdit
                            ? Icons.group_outlined
                            : Icons.visibility_outlined,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    // Flexible, or the Row hands the Text unbounded width
                    // and a long owner name overflows the Wrap on phones.
                    Flexible(
                      child: Text(
                        trip.canEdit
                            ? (trip.ownerName != null
                                ? l10n.tripCoPlanningWith(trip.ownerName!)
                                : l10n.tripCoPlanningShared)
                            : (trip.ownerName != null
                                ? l10n.tripSharedBy(trip.ownerName!)
                                : l10n.tripSharedViewOnly),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              if (trip.updatedByName != null)
                Text(
                  l10n.tripUpdatedBy(
                      trip.updatedByName!, _relativeTime(l10n, trip.updatedAt)),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ],
        if (overview != null) ...[
          const SizedBox(height: 12),
          // Self-contained show-more leaf: toggling it rebuilds this text
          // block only, not the whole screen.
          _OverviewText(
            text: overview,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _nextStepArea() {
    final trip = widget.trip;
    if (widget.readOnly) return const SizedBox.shrink();
    return Consumer(
      builder: (context, ref, _) {
        final review =
            ref.watch(tripReviewProvider(TripReviewKey(trip.id))).valueOrNull;
        final step = review?.nextStep;
        if (step == null) return const SizedBox.shrink();
        final allSet = step.kind == 'all_set';
        if (!allSet && !_hadNextStep) {
          // Record "this session saw a real step" post-frame (no setState in
          // build); the guard makes it one-shot.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_hadNextStep) setState(() => _hadNextStep = true);
          });
        }
        if (allSet && (!_hadNextStep || _allSetDismissed)) {
          return const SizedBox.shrink();
        }
        final progress = review?.planProgress;
        return NextStepCard(
          step: step,
          progress: progress,
          compact: widget.narrow,
          enabled: !widget.isOffline,
          // Same lookup the tap performs, so the label can never promise a
          // handoff the action won't make (specs/next-step-cta).
          transportHandsOff: widget.transportHandsOff(step),
          onPrimary: allSet ? null : () => widget.onNextStepAction(step),
          onViewAll: () => widget.onOpenHealthSheet(),
          // No ladder on the wire (older server, cached response) => no
          // affordance, rather than an entry point onto an empty sheet.
          onViewProgress: progress != null && progress.phases.isNotEmpty
              ? () => showPlanProgressSheet(context,
                  progress: progress, currentStep: step)
              : null,
          onDismiss:
              allSet ? () => setState(() => _allSetDismissed = true) : null,
        );
      },
    );
  }

  Widget _continueChatRow(ThemeData theme, AppLocalizations l10n) {
    final trip = widget.trip;
    final chat = trip.refineChat;
    if (chat == null || widget.panelOpen || !trip.canEdit || widget.isOffline) {
      return const SizedBox.shrink();
    }
    final updated = DateTime.tryParse(chat.updatedAt);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.forum_outlined),
          title: Text(l10n.tripContinueChat,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (chat.preview.isNotEmpty)
                Text(chat.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  // relativeTime already exists (offline_banner.dart) — reuse
                  // it rather than growing a second "how long ago" rule.
                  updated == null
                      ? l10n.tripContinueChatMeta(chat.messageCount, '')
                      : l10n.tripContinueChatMeta(
                          chat.messageCount, relativeTime(l10n, updated)),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          // A menu, not a bare icon: this sits a thumb's width from the row's
          // own onTap, which OPENS the conversation, and discarding one must
          // never be the near miss of resuming it. It is also the only way to
          // be rid of a saved chat without first opening it and waiting out a
          // full restore just to throw the transcript away.
          trailing: PopupMenuButton<String>(
            onSelected: (_) => widget.onNewChat(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(l10n.refineClearChat),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          onTap: () => widget.onOpenChat(),
        ),
      ),
    );
  }
}

/// How long ago an ISO timestamp was, in the app's three granularities.
String _relativeTime(AppLocalizations l10n, String iso) {
  final t = DateTime.tryParse(iso);
  if (t == null) return l10n.tripTimeRecently;
  final d = DateTime.now().difference(t.toLocal());
  if (d.inMinutes < 1) return l10n.tripTimeJustNow;
  if (d.inMinutes < 60) return l10n.tripTimeMinutesAgo(d.inMinutes);
  if (d.inHours < 24) return l10n.tripTimeHoursAgo(d.inHours);
  return l10n.tripTimeDaysAgo(d.inDays);
}

class _OverviewText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _OverviewText({required this.text, this.style});

  @override
  State<_OverviewText> createState() => _OverviewTextState();
}

class _OverviewTextState extends State<_OverviewText> {
  /// One constant read by BOTH the rendered Text.maxLines and the measuring
  /// painter, so the render and the toggle decision cannot drift.
  static const int _collapsedMaxLines = 2;

  bool _expanded = false;

  /// Whether the collapsed clamp would clip the text at [maxWidth] — the
  /// same verdict the collapsed Text's RenderParagraph reaches. Mirrors
  /// Text.build: DefaultTextStyle merge for inherited styles, the boldText
  /// accessibility merge (Text applies it internally; TextPainter does not),
  /// the ambient TextScaler OBJECT (Android 14+ scaling is nonlinear),
  /// directionality, locale, and the same ellipsis. Same measurement pattern
  /// as [_dateChipWidth].
  bool _collapsedClips(BuildContext context, double maxWidth) {
    var style = widget.style;
    if (style == null || style.inherit) {
      style = DefaultTextStyle.of(context).style.merge(style);
    }
    if (MediaQuery.boldTextOf(context)) {
      style = style.copyWith(fontWeight: FontWeight.bold);
    }
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: _collapsedMaxLines,
      ellipsis: '…',
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: maxWidth);
    final clips = tp.didExceedMaxLines;
    tp.dispose();
    return clips;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // LayoutBuilder so the toggle decision sees the exact width the Text
    // wraps at. Synchronous, one layout pass — no post-frame re-measure, so
    // the header extent is settled the frame it builds (the today-mode
    // auto-scroll in the hosting scroll view assumes settled extents).
    return LayoutBuilder(builder: (context, constraints) {
      // Unbounded width can't wrap, so it can't clip (and never occurs
      // under this stretched header column).
      final clips = constraints.maxWidth.isFinite &&
          _collapsedClips(context, constraints.maxWidth);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.text,
            style: widget.style,
            maxLines: _expanded ? null : _collapsedMaxLines,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
          // _expanded is deliberately not reset when the toggle disappears
          // (window grown until the text fits): expanded and collapsed
          // renders of fitting text are pixel-identical, so the stale flag
          // is unobservable.
          if (clips)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? l10n.tripShowLess : l10n.tripShowMore),
              ),
            ),
        ],
      );
    });
  }
}
