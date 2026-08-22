import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../widgets/account_menu.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/chat_panel.dart';
import '../widgets/destination_suggestion_card.dart';
import '../widgets/fading_edge_scroll.dart';
import '../widgets/near_me_chip.dart';
import '../widgets/random_suggestions.dart';
import '../providers/auth_provider.dart';
import '../providers/plan_provider.dart';
import '../providers/suggestions_provider.dart';
import '../widgets/page_container.dart';
import 'auth_screen.dart';
import 'trip_detail_screen.dart';

class AgentScreen extends ConsumerStatefulWidget {
  final String? initialMessage;

  /// When set (with [initialMessage]), reopens an existing trip for refinement:
  /// the conversation is bound to this chat group so new itineraries append as
  /// versions of that trip rather than creating a duplicate.
  final String? chatId;

  const AgentScreen({super.key, this.initialMessage, this.chatId});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.initialMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final notifier = ref.read(planProvider.notifier);
        if (widget.chatId != null) {
          notifier.beginRefinement(chatId: widget.chatId!, seedMessage: widget.initialMessage!);
        } else {
          notifier.sendMessage(widget.initialMessage!);
        }
      });
    }
  }

  /// Anonymous completions can't save; nudge sign-in so the NEXT plan does.
  /// Push (not replace) so the chat stays beneath in this tab's stack — the
  /// transcript survives sign-in because the plan notifier keeps its
  /// singleton ApiClient (the token mutates in place).
  void _openSignIn() {
    warmSsoAvailability(context);
    pushOnce(
      context,
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }

  void _openTrip(String tripId) {
    // pushOnce: the banner and the chat's own "view trip" both land here, so
    // this is reachable twice in a frame from two different widgets.
    pushOnce(
      context,
      locatedRoute(
          TripDetailScreen(tripId: tripId), tripDetailLocation(tripId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Narrow select so streaming-text flushes don't rebuild the Scaffold.
    final showReset = ref.watch(planProvider.select(
        (s) => s.messages.isNotEmpty || s.completedLocations != null));
    final l10n = context.l10n;

    return Scaffold(
      appBar: GradientAppBar(
        title: l10n.agentScreenTitle,
        actions: [
          if (showReset)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.read(planProvider.notifier).reset(),
              tooltip: l10n.agentScreenStartOver,
            ),
          const AccountMenu(),
        ],
      ),
      // Centered chat column on wide layouts: 760 = the 720 bubble cap plus
      // the list's horizontal padding. PageContainer's Center loosens only
      // minimum constraints, so the panel keeps its bounded height; the
      // 400px refine dock hosts the same ChatPanel and is unaffected.
      body: PageContainer(
        maxWidth: 760,
        child: ChatPanel(
          state: planProvider,
          notifier: planProvider.notifier,
          // The width-capped column exposes the full-bleed bar's square
          // corners mid-screen; float the composer as a rounded card here.
          floatingComposer: true,
          // The opening composes to the panel it gets, so it is built from
          // the panel's constraints rather than handed over as a fixed
          // widget — see _IntroTier for what the field gives up and when.
          emptyStateBuilder: (context, panel) => _PlanIntro(
            tier: _IntroTier.forField(context, panel),
            railCardWidth: _railCardWidthFor(panel.maxWidth),
            shortChipLabels: _shortChipLabelsFor(panel.maxWidth),
          ),
          // The same derivation, so the two cannot disagree: the field the
          // chosen tier needs is exactly the height at which joining it to
          // the composer fits.
          emptyStateJoinFloor: (context, panel) =>
              _IntroTier.forField(context, panel).fieldFor(context, panel),
          onViewTrip: _openTrip,
          footerBuilder: (context, state) => state.completedLocations == null
              ? const SizedBox.shrink()
              : _ItineraryBanner(
                  summary: state.completedSummary,
                  locationCount: state.completedLocations!.length,
                  onViewTrip: state.savedTripId == null
                      ? null
                      : () => _openTrip(state.savedTripId!),
                  // Sign-in nudge only for signed-out sessions; a signed-in
                  // unsaved completion (rare) shows the banner text alone.
                  onSignIn: ref.watch(authProvider
                          .select((s) => s.isSignedIn))
                      ? null
                      : _openSignIn,
                ),
        ),
      ),
    );
  }
}

/// One card of the destination rail, wide then narrow.
///
/// Two numbers because the rail's job is a COUNT — "two and a bit cards, the
/// next one cut by the edge" — and a count is not a width. 260 is the landing
/// rail's width and what the 760px column gets. A phone handed that same 260
/// shows 1.4 cards for 188px of a field that can be as short as 413: the block
/// that costs the most buying the least of what it exists to do. 150 restores
/// the count — two whole cards and a sliver at 375 — and hands 52px back.
///
/// The photo's aspect is identical either way, because
/// [DestinationSuggestionCard] scales its image band with the card, so nothing
/// crops differently. What changes is that the fixed two-line text band stops
/// being mostly empty.
const double _kRailCardWide = 260;
const double _kRailCardNarrow = 150;

/// Panel width at or above which the rail keeps the wide card: two wide cards,
/// the gap between them, and the rail's own padding. Derived from those parts
/// rather than written as a device breakpoint, so changing a card width cannot
/// leave this stale.
const double _kRailWideField =
    _kRailCardWide * 2 + AppSpacing.md + AppSpacing.lg * 2;

double _railCardWidthFor(double panelWidth) =>
    panelWidth >= _kRailWideField ? _kRailCardWide : _kRailCardNarrow;

/// Panel width below which the two chips take their short spelling — and, in
/// [_ChipStrip], a Row that cannot wrap.
///
/// A width question, like the rail's, and keyed to width rather than to how
/// tall the field is, so the same phone cannot show one row of chips in Safari
/// and two installed. Browser-measured at 390: "What's near me?" is 170 and
/// "Import from AI chat" 186, which with the 8 between them is 364 into 358 of
/// usable width — a second row for the sake of 6px. Spanish is the reason the
/// Row backs this up rather than the short labels alone: "¿Qué hay cerca de
/// mí?" is 210, so a Wrap took its second row anyway and pushed the composer
/// under the nav bar. Above this width the full spelling fits, and it is the
/// better copy.
const double _kChipsFullLabelField = 364 + AppSpacing.lg * 2;

bool _shortChipLabelsFor(double panelWidth) =>
    panelWidth < _kChipsFullLabelField;

/// How wide the intro paragraph is allowed to run. A centered measure, not the
/// column width: past ~50 characters a line the eye loses the return sweep,
/// and the whole point of this block is that it reads in one glance.
const double _kIntroMeasure = 420;

/// How much of the opening the field can actually hold.
///
/// Mobile web forced this. Browser-measured on the running app at 390 wide and
/// default text scale, the whole block plus the composer is 608px, and the
/// panel a phone offers is the viewport less the 56px app bar and the 84px nav
/// bar: 704 installed, but 524 in Safari with its chrome showing, and 413 on a
/// 375x667 device. At 524 both chips fell off the bottom; at 413 the
/// destination cards were sliced through their labels. Three of the four ways
/// in were invisible on the one screen whose whole job is offering them.
///
/// So the block composes to the field instead of overflowing it, and the order
/// it gives things up is fixed: air first, then the rail's photo size, then
/// prose. A way in is never what goes.
enum _IntroTier {
  /// Everything: the wide rail, the sentence, the xxl seam. The desktop
  /// column, a tablet, and an installed app on a modern phone.
  tall(
      chrome: 370,
      seam: AppSpacing.xxl,
      gapAboveChips: AppSpacing.lg,
      tailGap: AppSpacing.lg),

  /// Mobile web with browser chrome showing. The seams tighten by a rung;
  /// the sentence stays.
  medium(
      chrome: 354,
      seam: AppSpacing.xl,
      gapAboveChips: AppSpacing.lg,
      tailGap: AppSpacing.sm),

  /// The shortest phones. The explanatory sentence drops so the heading, all
  /// four ways in, and the composer stay on screen together — a first-timer
  /// can still act, which is what the sentence only described.
  short(
      chrome: 270,
      seam: AppSpacing.xl,
      gapAboveChips: AppSpacing.md,
      tailGap: AppSpacing.sm);

  const _IntroTier({
    required this.chrome,
    required this.seam,
    required this.gapAboveChips,
    required this.tailGap,
  });

  /// Everything this composition needs that is NOT the destination rail —
  /// heading, sentence if it keeps one, seams, the single chip row, and the
  /// composer it is placed with. Browser-measured on the running app at 390
  /// wide and default text scale; the rail is added at call time because it
  /// is the one block whose height still moves with the panel's width.
  final double chrome;

  /// The block's own seam, between the reading half and the acting half.
  final double seam;

  final double gapAboveChips;

  /// Below the chips, before [ChatPanel] adds its own lg and the composer's
  /// padding. Separate from [seam] because the two are answering different
  /// questions, and tying them together left the short field with 21px above
  /// the rail and 42px under the chips — the same air, badly spent.
  final double tailGap;

  bool get showsMessage => this != short;

  /// The field height this composition needs, rail included.
  double fieldFor(BuildContext context, BoxConstraints panel) =>
      chrome +
      DestinationSuggestionCard.heightFor(
          _railCardWidthFor(panel.maxWidth), MediaQuery.textScalerOf(context));

  /// The tallest composition the field can hold. Below [short] nothing fits —
  /// an open keyboard, the largest accessibility text — and [ChatPanel] keeps
  /// the composer on the floor and scrolls the block instead.
  static _IntroTier forField(BuildContext context, BoxConstraints panel) {
    for (final tier in values) {
      if (panel.maxHeight >= tier.fieldFor(context, panel)) return tier;
    }
    return short;
  }
}

/// The Plan tab before a word is typed.
///
/// ONE block — the reading half (heading + what the agent will do) over the
/// acting half (destination rail, then the two non-typing ways in) — that
/// [ChatPanel] joins with the composer into a single group on any field tall
/// enough to hold it, so the eye finishes the sentence on the thing it is
/// supposed to use. That adjacency is the redesign: every AI start screen
/// worth copying (and Mindtrip, the closest competitor) hangs its starters
/// off the composer, and the old layouts hung the block off the vertical
/// centre with hundreds of pixels of nothing underneath.
///
/// Deliberately NOT the shared [EmptyState] widget: that one is the app's
/// "nothing here yet" voice — icon, title, message, a Wrap of buttons, all
/// centered — and this is a designed opening, with a rail that has to run to
/// the column's edges and a block that has to sit off-centre.
class _PlanIntro extends ConsumerWidget {
  /// Which composition this field can hold. Chosen by [ChatPanel], which is
  /// the only widget that knows the panel's real constraints — inside the
  /// joined branch this block sits in a scroll view, where its own
  /// `maxHeight` would be unbounded and every tier would look like [tall].
  final _IntroTier tier;

  /// The rail's card width, from the panel's WIDTH. A separate question from
  /// [tier], which answers a question about height: a 1440x600 desktop is a
  /// short field that still deserves the wide card.
  final double railCardWidth;

  /// Also from the panel's WIDTH — see [_shortChipLabelsFor].
  final bool shortChipLabels;

  const _PlanIntro({
    required this.tier,
    required this.railCardWidth,
    required this.shortChipLabels,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    // The display face and its w500 come from the theme's headline tier —
    // never restated here, so this can't be the call site that ships
    // faux-bold.
    final reading = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.agentScreenEmptyTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
          // The sentence is the first thing the field gives up, and the only
          // thing: on a 375x667 phone in Safari there is no arrangement that
          // keeps it AND the four ways in, and a way in outranks a
          // description of one.
          if (tier.showsMessage) ...[
            const SizedBox(height: AppSpacing.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kIntroMeasure),
              child: Text(
                l10n.agentScreenEmptyMessage,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );

    final acting = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DestinationRail(cardWidth: railCardWidth),
        SizedBox(height: tier.gapAboveChips),
        // The two ways in that aren't typing and aren't a destination. Both
        // are chips now: side by side they are the same kind of offer, and a
        // chip beside an outlined button read as two ranks of one thing.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: _ChipStrip(
            // On a narrow panel this is a Row, not a Wrap, so ONE ROW is a
            // structural fact rather than a hope about label lengths. The
            // tier's chrome budget is measured against one row, and a Wrap
            // silently spending a second one is not a wrapped chip — it is
            // the composer pushed off the bottom of the screen, which is
            // exactly what Spanish did. Short labels keep the ellipsis from
            // ever being reached; the Row keeps a locale nobody measured
            // from breaking the composition.
            singleRow: shortChipLabels,
            children: [
              NearMeChip(
                compact: shortChipLabels,
                onSend: (text, {displayLabel}) => ref
                    .read(planProvider.notifier)
                    .sendMessage(text, displayLabel: displayLabel),
              ),
              // Planned elsewhere (ChatGPT/Claude)? Paste it in instead
              // (specs/import-trip-from-ai-chat). This one navigates — to the
              // Trips tab, same as /import's refresh-restore — rather than
              // putting words in the chat.
              ActionChip(
                avatar: const Icon(Icons.content_paste_go, size: 16),
                label: Text(
                  shortChipLabels ? l10n.importFromAiShort : l10n.importFromAi,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => openImportOnTripsTab(ref),
              ),
            ],
          ),
        ),
        SizedBox(height: tier.tailGap),
      ],
    );

    // ONE shrink-wrapped block; where it sits is not this widget's question
    // anymore. ChatPanel owns the vertical distribution: on a tall field the
    // composer joins the block and the air splits below it; on a short one
    // the block scrolls and the composer keeps the floor. (What must never
    // return here is a bias constant whose dartdoc explains machinery that
    // no longer runs.)
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        reading,
        // The block's own seam. A ladder value, not a share of the leftover:
        // it says how close these two halves are, which is a fixed
        // relationship, not a function of the viewport — the tier picks WHICH
        // rung, never a fraction between them.
        SizedBox(height: tier.seam),
        acting,
      ],
    );
  }
}

/// The opening's two chips, laid out so their row count is knowable.
///
/// [singleRow] false is the old [Wrap] — a wide panel has room for the full
/// labels and can afford a second row if some locale ever needs one. True is a
/// [Row] of [Flexible] chips: on a narrow panel the composition's whole height
/// budget is measured against one row of chips, so a Wrap that quietly takes a
/// second one costs 41px the field does not have.
class _ChipStrip extends StatelessWidget {
  final bool singleRow;
  final List<Widget> children;

  const _ChipStrip({required this.singleRow, required this.children});

  @override
  Widget build(BuildContext context) {
    if (!singleRow) {
      return Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        alignment: WrapAlignment.center,
        children: children,
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, child) in children.indexed) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Flexible(child: child),
        ],
      ],
    );
  }
}

/// The shuffled destination pool as a horizontal rail of photo cards.
///
/// Replaces the one-card-at-a-time carousel this screen shipped with. That
/// carousel answered a real objection — a rail that sits still hides its picks
/// behind a scroll nobody is invited to try — but it answered it by moving,
/// which costs a timer, dot pagination, and a five-second wait to see a second
/// idea. The rail shows two and a bit at once with the next one cut by the
/// edge, which is the invitation the still rail lacked; it is the same move
/// the landing page's rail already shipped, so the two surfaces now speak once.
///
/// Tapping a card sends exactly its visible label: it becomes a message in the
/// traveler's own transcript, so an English message they never wrote would read
/// as a bug. The agent answers in their language anyway (specs/i18n-spanish).
class _DestinationRail extends ConsumerWidget {
  /// Set by [_PlanIntro] from the panel's width — see [_railCardWidthFor].
  final double cardWidth;

  const _DestinationRail({required this.cardWidth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RandomSuggestions(
      // The whole pool in a shuffled order, not a three-pick sample: a rail
      // can scroll, so it can carry the full range of destinations.
      picker: suggestionOrderProvider,
      builder: (context, prompts) => SizedBox(
        height: DestinationSuggestionCard.heightFor(
            cardWidth, MediaQuery.textScalerOf(context)),
        child: ScrollConfiguration(
          // Without this a mouse cannot drag the rail on web/desktop — the
          // same reason the landing rail and the chat photo strips set it.
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: PointerDeviceKind.values.toSet(),
          ),
          // The pool is longer than any window, so this rail always runs off
          // the edge. Without the fade it ended on a hard cut that read like
          // the last card rather than a cropped one — the same complaint the
          // home rails answered, so the same widget answers it here.
          child: FadingEdgeScroll(
            builder: (context, controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              itemCount: prompts.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
              itemBuilder: (context, i) {
                final p = prompts[i];
                return DestinationSuggestionCard(
                  prompt: p.text,
                  asset: p.asset,
                  credit: p.credit,
                  width: cardWidth,
                  onTap: () =>
                      ref.read(planProvider.notifier).sendMessage(p.text),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ItineraryBanner extends StatelessWidget {
  final String? summary;
  final int locationCount;
  final VoidCallback? onViewTrip;

  /// Sign-in nudge for anonymous completions (the trip couldn't save); the
  /// copy promises the NEXT plan saves — no retro-save exists.
  final VoidCallback? onSignIn;

  const _ItineraryBanner({
    this.summary,
    required this.locationCount,
    this.onViewTrip,
    this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('itinerary-banner'),
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      // Tint fill (no border) separates this from the chat — spacing/tint over
      // borders.
      decoration: BoxDecoration(
        color: AppColors.brandTint,
        borderRadius: AppRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: AppColors.brand, size: 22),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  context.l10n.agentScreenItineraryReady(locationCount),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppColors.brandDark,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (summary != null && summary!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              summary!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.brandDark.withValues(alpha: 0.85),
              ),
            ),
          ],
          // When the trip was saved, opening it is the one action — the
          // full itinerary, bookings, and map all live there. Anonymous
          // sessions couldn't save, so nudge sign-in for the next plan;
          // signed-in-but-unsaved (rare) needs no button at all.
          if (onViewTrip != null) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onViewTrip,
                icon: const Icon(Icons.luggage),
                label: Text(context.l10n.agentScreenViewTrip),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandLight,
                ),
              ),
            ),
          ] else if (onSignIn != null) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onSignIn,
                icon: const Icon(Icons.login),
                label: Text(context.l10n.agentScreenSignInToSave),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandLight,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
