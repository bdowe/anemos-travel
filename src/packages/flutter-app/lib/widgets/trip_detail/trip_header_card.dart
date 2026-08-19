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

  /// Attached to the title Text so the screen can measure where it sits and
  /// hand the name to the app bar once it has scrolled away. Optional: the
  /// card renders identically without one, and nothing here reads it.
  final GlobalKey? titleKey;

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
    this.titleKey,
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
          // Centered, not top-aligned: the pencil's tap target is taller than
          // the title line, and a start-aligned row parks the title at the top
          // of that box — so the "8px" gap below rendered as ~30px and the
          // name floated away from the dates it belongs to (the TripAdvisor
          // reference stacks title and meta as one block). Centering spends
          // the button's slack symmetrically and lets the gap below be the
          // real one.
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                widget.displayTitle,
                // Keyed so the screen can measure when this title has scrolled
                // out from under the app bar and take the name over up there
                // (the collapse). The key rides in from the screen because the
                // screen is what owns the scroll listener; this widget only
                // has to hand it the render object.
                key: widget.titleKey,
                // The heading face at title size — the same register the
                // itinerary's pinned city headers take, now stated once in
                // [AppTextStyles.sectionHeading]. This block is a compact
                // anchor, so it must not inflate into the hero panel the
                // comment above rules out; that is exactly what the register
                // means. Reached this style via titleLarge + fontFamily before
                // the token, which silently kept M3's titleLarge line height
                // rather than the headline register's 1.2.
                style: AppTextStyles.sectionHeading(theme.textTheme),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trip.canEdit)
              IconButton(
                icon: const Icon(Icons.edit, size: 20),
                tooltip: l10n.tripEditDetails,
                // Compact (40px, the pinned tab row's density) so the chrome
                // affordance stops setting the identity block's line height.
                visualDensity: VisualDensity.compact,
                onPressed: widget.isOffline ? null : widget.onEditDetails,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
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
            //
            // An ActionChip, not a tonal FilledButton — this is the entry that
            // finally makes the demotion true. As a filled button it was the
            // loudest thing in the top 200px and it rhymed exactly with the
            // Next Step card's own tonal CTA ~130px below ("Refine with AI"
            // over "Find lodging"), so the header opened with two equal-weight
            // teal buttons asking for the same kind of attention. The header
            // now carries exactly ONE filled action — the next step's — and
            // refine reads as what the comment above always claimed: a peer of
            // the dates chip. The brand stays, at chip-and-pin scale, in the
            // sparkle.
            if (trip.canEdit && !widget.narrow)
              ActionChip(
                avatar: Icon(Icons.auto_awesome,
                    size: 16, color: theme.colorScheme.primary),
                label: Text(l10n.tripRefineWithAI),
                // Chat/refine needs the network — disabled while offline.
                onPressed: widget.isOffline ? null : widget.onRefine,
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

  /// The saved-conversation row, rendered as the Next Step card's quiet
  /// sequel rather than as a second, unrelated card.
  ///
  /// It used to be an elevated Material [Card] sitting `AppSpacing.md` below a
  /// flat tinted panel: two boxes in two different depth registers, doing one
  /// job each — "what to do next" and "where you left off" — and reading as
  /// two unrelated surfaces stacked on the page. They are now one sequence:
  /// same corner radius, the same 24px leading-icon column and `AppSpacing.md`
  /// icon gutter as [NextStepCard], and only `AppSpacing.sm` between them, so
  /// the pair scans as one plan block whose second line is quieter than its
  /// first. Flat, not elevated — the post-#494 doctrine, and a shadow here
  /// would put the SECONDARY entry above the primary one in depth.
  ///
  /// Deliberately NOT merged into the tinted panel itself. The original reason
  /// was that [NextStepCard] painted a fixed light `brandTint` in both themes,
  /// so a shared field would have doubled that light block in dark mode; the
  /// tint is brightness-aware now ([AppColors.brandTintFill]), so that
  /// particular hazard is gone. The decision stands on the other half of its
  /// rationale: these are two jobs — "what to do next" and "where you left
  /// off" — and one tinted field would give the quieter one the emphasis of
  /// the louder. Sequence, not fusion.
  Widget _continueChatRow(ThemeData theme, AppLocalizations l10n) {
    final trip = widget.trip;
    final chat = trip.refineChat;
    if (chat == null || widget.panelOpen || !trip.canEdit || widget.isOffline) {
      return const SizedBox.shrink();
    }
    final updated = DateTime.tryParse(chat.updatedAt);
    // relativeTime already exists (offline_banner.dart) — reuse it rather than
    // growing a second "how long ago" rule.
    final meta = updated == null
        ? l10n.tripContinueChatMeta(chat.messageCount, '')
        : l10n.tripContinueChatMeta(
            chat.messageCount, relativeTime(l10n, updated));
    final mutedStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Container(
      // Addressable the way NextStepCard's own ValueKey is: the screen carries
      // several PopupMenuButton<String>s, and scoping to this row's structure
      // is what broke when the row stopped being a ListTile.
      key: const ValueKey('continue-chat-row'),
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.mdAll,
      ),
      child: InkWell(
        borderRadius: AppRadius.mdAll,
        onTap: () => widget.onOpenChat(),
        child: Padding(
          // Left/top/bottom match NextStepCard's uniform lg inset; the trailing
          // side is tightened to sm because the menu button carries its own.
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
          child: Row(
            children: [
              Icon(Icons.forum_outlined,
                  size: 24, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title and meta share a line via a Wrap: on a phone (or in
                    // Spanish, where both strings are longer) the counter drops
                    // to its own line instead of ellipsizing the label the
                    // tests — and the traveler — tap.
                    Wrap(
                      spacing: AppSpacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(l10n.tripContinueChat,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        Text(meta, style: mutedStyle),
                      ],
                    ),
                    if (chat.preview.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(chat.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: mutedStyle),
                    ],
                  ],
                ),
              ),
              // A menu, not a bare icon: this sits a thumb's width from the
              // row's own onTap, which OPENS the conversation, and discarding
              // one must never be the near miss of resuming it. It is also the
              // only way to be rid of a saved chat without first opening it and
              // waiting out a full restore just to throw the transcript away.
              PopupMenuButton<String>(
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
            ],
          ),
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
