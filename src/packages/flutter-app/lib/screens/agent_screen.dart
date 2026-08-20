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
          emptyState: const _PlanIntro(),
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

/// One card of the destination rail. The landing rail's width, because the two
/// photo rails in the product are the same component doing the same job and a
/// second number would only be a second number.
const double _kRailCardWidth = 260;

/// How wide the intro paragraph is allowed to run. A centered measure, not the
/// column width: past ~50 characters a line the eye loses the return sweep,
/// and the whole point of this block is that it reads in one glance.
const double _kIntroMeasure = 420;

/// Below this the reading block stops floating in a field of its own and joins
/// the scroll with everything else. Measured against the shortest viewport the
/// screen has to hold (a 568pt phone, less the app bar and the composer, is
/// ~430) rather than guessed from a width breakpoint — the thing that runs out
/// here is height, so height is what is asked.
const double _kIntroFieldFloor = 440;

/// The Plan tab before a word is typed.
///
/// Composed as ONE block that ends at the composer instead of a centered card
/// marooned in the middle of the panel: the reading half (heading + what the
/// agent will do) takes an open field over its head, and the acting half
/// (destination rail, then the two non-typing ways in) sits directly above the
/// input, so the eye finishes the sentence on the thing it is supposed to use. That adjacency is the redesign — every AI start screen
/// worth copying (and Mindtrip, the closest competitor) hangs its starters off
/// the composer, and the old layout hung them off the vertical centre with
/// ~200px of nothing underneath.
///
/// Deliberately NOT the shared [EmptyState] widget: that one is the app's
/// "nothing here yet" voice — icon, title, message, a Wrap of buttons, all
/// centered — and this is a designed opening, with a rail that has to run to
/// the column's edges and a block that has to sit off-centre.
class _PlanIntro extends ConsumerWidget {
  const _PlanIntro();

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
      ),
    );

    final acting = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _DestinationRail(),
        const SizedBox(height: AppSpacing.lg),
        // The two ways in that aren't typing and aren't a destination. Both
        // are chips now: side by side they are the same kind of offer, and a
        // chip beside an outlined button read as two ranks of one thing.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            alignment: WrapAlignment.center,
            children: [
              NearMeChip(
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
                label: Text(l10n.importFromAi),
                onPressed: () => openImportOnTripsTab(ref),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < _kIntroFieldFloor) {
          return SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.xl),
                reading,
                const SizedBox(height: AppSpacing.xl),
                acting,
              ],
            ),
          );
        }
        return Column(
          children: [
            Expanded(
              // Whatever height is left over splits 3:1 in favour of the field
              // ABOVE the heading. Space over a heading reads as composure —
              // it is the move the editorial references make — while the same
              // space under it reads as a missing element, which is exactly
              // how the centred layout this replaces read.
              child: Align(
                alignment: const Alignment(0, 0.5),
                // Loose constraints from Align, so this shrink-wraps unless
                // the largest text scales make the block taller than its
                // share — then it scrolls instead of overflowing.
                child: SingleChildScrollView(child: reading),
              ),
            ),
            acting,
          ],
        );
      },
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
  const _DestinationRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RandomSuggestions(
      // The whole pool in a shuffled order, not a three-pick sample: a rail
      // can scroll, so it can carry the full range of destinations.
      picker: suggestionOrderProvider,
      builder: (context, prompts) => SizedBox(
        height: DestinationSuggestionCard.heightFor(
            _kRailCardWidth, MediaQuery.textScalerOf(context)),
        child: ScrollConfiguration(
          // Without this a mouse cannot drag the rail on web/desktop — the
          // same reason the landing rail and the chat photo strips set it.
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: PointerDeviceKind.values.toSet(),
          ),
          child: ListView.separated(
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
                width: _kRailCardWidth,
                onTap: () =>
                    ref.read(planProvider.notifier).sendMessage(p.text),
              );
            },
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
