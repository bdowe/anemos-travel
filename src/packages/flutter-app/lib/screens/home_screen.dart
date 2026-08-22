import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/local_guide.dart';
import '../providers/auth_provider.dart';
import '../providers/departing_trip_provider.dart';
import '../providers/live_trip_provider.dart';
import '../providers/local_provider.dart';
import '../providers/plan_provider.dart';
import '../providers/recent_trip_provider.dart';
import '../providers/resumable_chats_provider.dart';
import '../providers/suggestions_provider.dart';
import '../providers/trips_provider.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../theme/app_colors.dart';
import '../theme/app_shadows.dart';
import '../theme/spacing.dart';
import '../widgets/account_menu.dart';
import '../widgets/before_you_go_section.dart';
import '../widgets/continue_chats_section.dart';
import '../widgets/continue_trip_hero.dart';
import '../widgets/fading_edge_scroll.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/home_inspiration_rail.dart';
import '../widgets/home_next_step_band.dart';
import '../widgets/home_travels_band.dart';
import '../widgets/language_menu_button.dart';
import '../widgets/live_trip_card.dart';
import '../widgets/near_me_chip.dart';
import '../widgets/page_container.dart';
import '../widgets/random_suggestions.dart';
import '../widgets/section_header.dart';
import 'guides_screen.dart';
import 'local_guide_detail_screen.dart';

/// Which time-of-day greeting the home header shows. The variant is chosen
/// without a BuildContext (and unit-tested that way); [greetingText] maps it to
/// localized copy at render time (specs/i18n-spanish).
enum Greeting { morning, afternoon, evening }

/// Time-of-day greeting for the home header.
@visibleForTesting
Greeting greetingForHour(int hour) {
  if (hour < 12) return Greeting.morning;
  if (hour < 17) return Greeting.afternoon;
  return Greeting.evening;
}

String greetingText(AppLocalizations l10n, Greeting greeting) =>
    switch (greeting) {
      Greeting.morning => l10n.homeGreetingMorning,
      Greeting.afternoon => l10n.homeGreetingAfternoon,
      Greeting.evening => l10n.homeGreetingEvening,
    };


class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Owned explicitly rather than relying on `primary: true`: the implicit
  /// primary-controller attach is platform-gated to mobile, so on web the
  /// brand tap would silently have nothing to scroll.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Logo-links-home, plus Home's own extra: scroll back to the top.
  ///
  /// [GradientAppBar] already wires [goHome] for every screen inside the
  /// shell, so this override exists only for the scroll — which is also the
  /// visible half here. Each tab owns its own Scaffold (the shell supplies no
  /// app bar), so this particular brand is on screen only at the Home root,
  /// where [goHome] is a no-op-you-can't-see. It stays for contract parity
  /// with the rail brand (app_shell.dart `_RailBrand`), which CAN be tapped
  /// from anywhere.
  void _onBrandTap() {
    goHome(ref);
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    // Narrow selects throughout: Home only decorates what other screens load
    // (a background trips refresh emits several states), so every watch is
    // scoped to the minimal shape this build actually renders — records
    // compare structurally, so an unchanged shape means no rebuild of the
    // hero/greeting/guides subtree.
    final displayName =
        ref.watch(authProvider.select((s) => s.user?.displayName));
    // Derived, never read straight off device storage: continueTripProvider
    // prefers the trip this device last viewed and falls back to the trips
    // list when this origin has no record of one (new device, cleared
    // storage, domain move) — precedence in continueTripOf. It already
    // excludes the live trip, so nothing here has to.
    final continueTrip = ref.watch(continueTripProvider);
    // A SEPARATE question from the one above: the trip departing soonest
    // inside the readiness window, which is what "before you go" means. Also
    // live-trip-excluding, so nothing here has to. See departingTripOf.
    final departingTrip = ref.watch(departingTripProvider);
    // Populated app-wide: AppShell's IndexedStack keeps TripsListScreen
    // mounted, and its loadTrips() feeds tripsProvider — no fetch from here.
    //
    // Every trips refresh rebuilds the Trip objects, so watching the derived
    // Trip? directly would fire on identical data. Watch an identity-stable
    // key instead — (id, updatedAt) is the server's change marker, so equal
    // key means equal row — and read the full object (for LiveTripCard) only
    // when the key says this build runs anyway.
    final liveTripKey = ref.watch(liveTripProvider
        .select((t) => t == null ? null : (id: t.id, updatedAt: t.updatedAt)));
    final liveTrip = liveTripKey == null ? null : ref.read(liveTripProvider);
    // Returning users (anything to come back to) get the compact plan strip
    // instead of the 440px photo hero, so their trips sit above the fold.
    // While providers are still loading this reads false and the full hero
    // shows briefly — same async-appearance behavior as LiveTripCard.
    final returning = liveTrip != null ||
        continueTrip != null ||
        ref.watch(tripsProvider.select((s) => s.trips.isNotEmpty)) ||
        ref.watch(resumableChatsProvider
            .select((a) => a.valueOrNull?.isNotEmpty ?? false));

    // The chat is a persistent tab, so "Let's go" / a suggestion switches to it
    // (and seeds the message) rather than pushing a one-off screen.
    // displayLabel renders the seed as a compact context chip (near-me sends
    // coordinates the traveler shouldn't have to read back).
    void startPlanning({String? initialMessage, String? displayLabel}) {
      ref.read(navIndexProvider.notifier).state = AppTab.plan.index;
      if (initialMessage != null && initialMessage.isNotEmpty) {
        ref
            .read(planProvider.notifier)
            .sendMessage(initialMessage, displayLabel: displayLabel);
      }
    }

    return Scaffold(
      appBar: GradientAppBar(
        // No page title: on Home the brand IS the title.
        onBrandTap: _onBrandTap,
        actions: const [LanguageMenuButton(), AccountMenu()],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: PageContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: AppSpacing.lg),

                _GreetingHeader(displayName: displayName),

                // Space, not size, marks the greeting as the page's display
                // moment — the largest gap on the page sits under it.
                const SizedBox(height: AppSpacing.xxl),

                // AI Travel Agent entry: the full photo hero sells the
                // product to a brand-new account; returning users get a slim
                // strip with the same CTA so their trips stay above the fold.
                if (returning) ...[
                  _PlanStrip(onStart: startPlanning),
                  // The strip row is width-starved on phones, so the near-me
                  // starter sits on its own line beneath it.
                  const SizedBox(height: AppSpacing.md),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: NearMeChip(
                      onSend: (text, {displayLabel}) => startPlanning(
                          initialMessage: text, displayLabel: displayLabel),
                    ),
                  ),
                ] else
                  _AgentHeroCard(
                    onStart: startPlanning,
                    onImport: () => openImportOnTripsTab(ref),
                  ),

                const SizedBox(height: AppSpacing.xl),

                // The trip happening today (specs/happening-now).
                if (liveTrip != null) ...[
                  LiveTripCard(
                    trip: liveTrip,
                    // The trips list owns this trip's route band; a second
                    // one here would starve it (see TripHeroCard.showMap).
                    showMap: false,
                    // On the Trips tab (not pushed over Home): the Trips nav
                    // item highlights, and `from` sends back here rather than
                    // to a trips list this traveler never opened.
                    onTap: () =>
                        openTripOnTripsTab(ref, liveTrip.id, from: AppTab.home),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                ],
                // One "Continue where you left off" section: the trip to pick
                // back up (see continueTripProvider), then in-progress AI
                // conversations that haven't produced a trip yet
                // (specs/continue-where-you-left-off). Collapses to nothing
                // only when the account genuinely has nothing to resume.
                ContinueChatsSection(
                  leading: continueTrip != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ContinueTripHero(
                              tripId: continueTrip.tripId,
                              title: continueTrip.title,
                              dateRange: continueTrip.dateRange,
                              startDate: continueTrip.startDate,
                              onTap: () => openTripOnTripsTab(
                                  ref, continueTrip.tripId,
                                  from: AppTab.home),
                            ),
                            // The hero's quiet sequel: what that trip still
                            // needs. Collapses to nothing whenever the review
                            // has no step to report, so the gap below is the
                            // section's own — see HomeNextStepBand.
                            const SizedBox(height: AppSpacing.sm),
                            HomeNextStepBand(
                              tripId: continueTrip.tripId,
                              // Same destination AND same origin as the hero
                              // above it: the pair is one target with two
                              // rows, so back has to land where the hero's
                              // back lands (PR #516).
                              onTap: () => openTripOnTripsTab(
                                  ref, continueTrip.tripId,
                                  from: AppTab.home),
                            ),
                          ],
                        )
                      : null,
                ),

                // Pre-departure readiness for the trip that is close enough to
                // pack for — which is departingTripProvider's trip, NOT the
                // continue-trip above. The two answer different questions
                // ("what am I about to take" vs "what did I last open"), and
                // reading readiness off the second one silently reported the
                // wrong trip whenever they disagreed. The card prints the name
                // it is talking about either way. Renders nothing when it has
                // no honest row to show (BeforeYouGoSection).
                if (departingTrip != null)
                  BeforeYouGoSection(
                    tripId: departingTrip.tripId,
                    tripTitle: departingTrip.title,
                    startDate: departingTrip.startDate,
                    // The health sheet, not the trip page: this card's rows
                    // ARE that sheet's rows, and it is the only surface with
                    // buttons that can act on them.
                    onTap: () => openTripHealthOnTripsTab(
                        ref, departingTrip.tripId,
                        from: AppTab.home),
                  ),

                // Where the traveler has been, and where they are going next.
                // Carries its own 2+ owned-trips gate, so it cannot appear
                // half-empty on a first trip.
                const HomeTravelsBand(),

                // Inspiration no longer disappears the moment there is a trip
                // to continue. The rule it used to enforce — inspiration must
                // never push a traveler's actual trips down — is now kept by
                // POSITION rather than by absence: the rail sits below the
                // trip content instead of vanishing from the page. Gating it
                // off inverted the intent in practice, because the traveler
                // who HAD a trip got the emptiest home screen in the app.
                HomeInspirationRail(
                  onPrompt: (text) => startPlanning(initialMessage: text),
                ),

                // Local guides discover row — published narrative guides
                // across all cities. Renders nothing while loading, on
                // error, or when there are none, so the section (header
                // included) only appears when there is something to show.
                const _LocalGuidesRow(),

                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact sibling of [_AgentHeroCard] for returning users: one quiet card
/// row — icon, headline, CTA. De-tealed in the editorial pass: the page's
/// saturated statements are the continue hero's imagery and this row's one
/// teal button, so the strip itself sits on the ambient card surface
/// (cardTheme supplies radius, downward shadow, and the dark-mode tonal
/// step). No photo, no suggestion chips; the Plan tab has free input.
class _PlanStrip extends StatelessWidget {
  final void Function({String? initialMessage, String? displayLabel}) onStart;

  const _PlanStrip({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onStart(),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Icon(Icons.flight_takeoff,
                  color: theme.colorScheme.primary, size: 26),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Text(
                  l10n.homeHeroTitle,
                  // Two lines before ellipsis: at phone widths the CTA
                  // starves the row and one line truncates the tagline
                  // ("Plan less. Trav…").
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  // titleMedium already carries the row's weight (w600 via
                  // the theme); below the headline, hierarchy is weight.
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              FilledButton(
                onPressed: () => onStart(),
                child: Text(l10n.homeHeroCta),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GreetingHeader extends StatelessWidget {
  final String? displayName;

  const _GreetingHeader({required this.displayName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final firstName = displayName?.trim().split(RegExp(r'\s+')).first;
    final greeting = greetingText(l10n, greetingForHour(DateTime.now().hour));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (firstName == null || firstName.isEmpty)
              ? greeting
              : l10n.homeGreetingNamed(greeting, firstName),
          // The page's one display moment: headlineMedium is the display
          // face via the theme, a step above the old headlineSmall.
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.homeGreetingSubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _AgentHeroCard extends StatelessWidget {
  final void Function({String? initialMessage, String? displayLabel}) onStart;
  final VoidCallback onImport;

  const _AgentHeroCard({required this.onStart, required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadius.lgAll,
        boxShadow: AppShadows.hero,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.lgAll,
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/images/hero_santorini.jpg',
                fit: BoxFit.cover,
              ),
            ),
            // Scrim: darkest in the lower-left where the text and button sit,
            // lighter toward the upper-right so the photo shows through.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: AppColors.heroScrim),
              ),
            ),
            _heroContent(context),
          ],
        ),
      ),
    );
  }

  Widget _heroContent(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Container(
      constraints: const BoxConstraints(minHeight: 440),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bare on the scrim — the editorial pass deleted the translucent
          // circle plate (icon plates read as chrome, not craft).
          const Icon(Icons.flight_takeoff, size: 44, color: Colors.white),
          const SizedBox(height: AppSpacing.lg),
          Text(
            l10n.homeHeroTitle,
            // headlineLarge (display face, 34) — the signed-in echo of the
            // landing hero's display tier, via the theme role.
            style: theme.textTheme.headlineLarge?.copyWith(
              color: Colors.white,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.homeHeroSubtitle,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => onStart(),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.brandDark,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                shape: const RoundedRectangleBorder(
                  borderRadius: AppRadius.mdAll,
                ),
              ),
              child: Text(
                l10n.homeHeroCta,
                // titleMedium keeps the deliberate 16px hero-CTA size while
                // deriving from the type scale instead of a raw fontSize.
                style: theme.textTheme.titleMedium?.copyWith(
                  color: AppColors.brandDark,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          RandomSuggestions(
            // A sample, not the pool: these are static chips on a hero photo
            // with room for three.
            picker: suggestionPickerProvider,
            builder: (context, prompts) => Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                NearMeChip(
                  onSend: (text, {displayLabel}) => onStart(
                      initialMessage: text, displayLabel: displayLabel),
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.brandDark,
                  labelStyle: theme.textTheme.labelMedium?.copyWith(
                      color: AppColors.brandDark, fontWeight: FontWeight.w500),
                ),
                // Chips, not photo cards: this hero already sits on the
                // Santorini photo, and cards on top of it would be
                // photo-on-photo (specs/destination-suggestion-cards). Only
                // the drawn text is used here.
                ...prompts.map((s) => ActionChip(
                      label: Text(s.text,
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: AppColors.brandDark,
                              fontWeight: FontWeight.w500)),
                      backgroundColor: Colors.white,
                      side: BorderSide.none,
                      onPressed: () => onStart(initialMessage: s.text),
                    )),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Already planned in ChatGPT/Claude? Its own line, not another
          // chip: the chips above put words into the chat, this navigates
          // (specs/import-trip-from-ai-chat).
          TextButton.icon(
            onPressed: onImport,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.content_paste_go, size: 18),
            label: Text(l10n.importFromAi),
          ),
        ],
      ),
    );
  }
}

/// Horizontal discover row of published local guides across all cities.
/// Collapses to nothing (header included) while loading, on error, or when
/// no guides are published yet — the home screen just reads as before.
class _LocalGuidesRow extends ConsumerWidget {
  const _LocalGuidesRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guides = ref.watch(allGuidesProvider).maybeWhen(
          data: (g) => g,
          orElse: () => const <LocalGuide>[],
        );
    if (guides.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: context.l10n.homeLocalGuidesTitle,
          action: TextButton(
            onPressed: () => pushOnce(
              context,
              locatedRoute(
                  const GuidesScreen(), utilityLocation(BootUtility.guides)),
            ),
            child: Text(context.l10n.commonSeeAll),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 190,
          // Same treatment as the inspiration rail below it — the two sit on
          // one page at one card rhythm, so a hard cut on this one would
          // read as a bug beside a faded one.
          child: FadingEdgeScroll(
            builder: (context, controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              // Room below the cards so their drop shadow isn't clipped by
              // the horizontal viewport.
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              itemCount: guides.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
              itemBuilder: (context, i) => _GuideCard(guide: guides[i]),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// One tappable guide card in the discover row: hero image (branded fallback
/// when missing/broken), title, city, and the local's byline.
class _GuideCard extends StatelessWidget {
  final LocalGuide guide;

  const _GuideCard({required this.guide});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.toolLocal(theme.brightness);

    return SizedBox(
      width: 230,
      // Card, not a hand-rolled Container: cardTheme carries the radius,
      // the downward shadow, and the dark-mode tonal step in one place.
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // Unnamed on purpose: the screen takes the full guide object, so a
          // URL couldn't reconstruct it — refresh lands on the page beneath.
          onTap: () => pushOnce(
            context,
            MaterialPageRoute(
              builder: (_) => LocalGuideDetailScreen(guide: guide),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 88,
                width: double.infinity,
                child: guide.heroImageUrl.isNotEmpty
                    ? Image.network(
                        guide.heroImageUrl,
                        fit: BoxFit.cover,
                        // Bound the decode to the 230px card slot (DPR-scaled)
                        // so a full-size hero photo never decodes at native
                        // resolution for an 88px-tall tile.
                        cacheWidth:
                            (230 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
                        errorBuilder: (_, __, ___) =>
                            const _GuideImageFallback(),
                      )
                    : const _GuideImageFallback(),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        guide.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // titleSmall already carries w600 via the theme.
                        style: theme.textTheme.titleSmall,
                      ),
                      if (guide.city.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          guide.city,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (guide.sourceName.isNotEmpty)
                        Row(
                          children: [
                            Icon(Icons.verified, size: 14, color: accent),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: Text(
                                context.l10n.homeGuideByline(guide.sourceName),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                // Quiet byline: the verified mark carries the
                                // "local" accent alone; running text stays
                                // neutral (color is never decoration).
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Branded placeholder for a guide card whose hero image is missing or fails
/// to load — same treatment as the detail screen's hero fallback.
class _GuideImageFallback extends StatelessWidget {
  const _GuideImageFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: AppColors.brandGradient),
      alignment: Alignment.center,
      child: const Icon(Icons.menu_book, size: 28, color: Colors.white70),
    );
  }
}
