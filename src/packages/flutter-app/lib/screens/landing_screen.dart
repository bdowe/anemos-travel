import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../providers/analytics_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/spacing.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/language_menu_button.dart';
import '../widgets/page_container.dart';
import 'auth_screen.dart';
import 'landing/landing_cta_band.dart';
import 'landing/landing_destination_rail.dart';
import 'landing/landing_feature_grid.dart';
import 'landing/landing_footer.dart';
import 'landing/landing_hero.dart';
import 'landing/landing_how_it_works.dart';
import 'landing/landing_layout.dart';
import 'landing/landing_section_title.dart';

/// Marketing entry point shown to logged-out visitors (specs/landing-redesign).
/// The hero IS the product's first interaction — a real prompt input whose
/// submit hands the text to the landing handoff (specs/landing-prompt-handoff)
/// — followed by the feature grid, destination rail, how-it-works, and the
/// closing CTA. "Sign in" opens login; on success the AuthGate swaps this
/// screen for the app automatically.
///
/// The whole route commits to the dark brand look via a local `Theme` wrap,
/// regardless of the visitor's theme mode — routes pushed from here rebuild
/// under the MaterialApp themes as normal. One caveat: overlay-routed
/// surfaces (the language menu's popup) inherit the navigator's theme, not
/// this wrap — same as before the redesign; don't "fix" it here.
///
/// Rendering this screen records the anonymous `landing_viewed` analytics
/// event — the top of the activation funnel — at most once per app session
/// (guarded by a static, so rebuilds and sign-out round trips don't
/// re-record).
class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  /// True once this app session has recorded `landing_viewed`.
  static bool _viewRecorded = false;

  /// Resets the once-per-session guard so widget tests can assert on it.
  @visibleForTesting
  static void resetViewRecordedForTest() => _viewRecorded = false;

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  @override
  void initState() {
    super.initState();
    if (!LandingScreen._viewRecorded) {
      LandingScreen._viewRecorded = true;
      try {
        // Fire-and-forget; listen: false is safe in initState. A widget tree
        // without a ProviderScope must never break the landing page.
        ProviderScope.containerOf(context, listen: false)
            .read(analyticsApiServiceProvider)
            .recordLandingViewed();
      } catch (_) {
        // Tracking must never affect the visitor's experience.
      }
    }
  }

  static void _openAuth(BuildContext context, {required bool isLogin}) {
    // Start the SSO availability fetches now so the route transition covers
    // the round trip and the auth form doesn't get shoved down on arrival.
    warmSsoAvailability(context);
    pushOnce(
      context,
      MaterialPageRoute(
        builder: (_) => AuthScreen(initialIsLogin: isLogin),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Theme(
      data: AppTheme.dark,
      child: Scaffold(
        backgroundColor: AppColors.landingCanvas,
        appBar: GradientAppBar(
          // No page title: the landing page's title is the brand. The bar's
          // own lockup (bare mark + wordmark, plate policy v3) comes from
          // GradientAppBar — this screen sits outside the shell, so it keeps
          // the mark at every width.
          actions: [
            const LanguageMenuButton(),
            TextButton(
              onPressed: () => _openAuth(context, isLogin: true),
              child: Text(l10n.landingSignIn),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            // Full-bleed sections own their padding; the hero runs
            // edge-to-edge under the opaque bar (dark surface here — this
            // screen forces AppTheme.dark), separated by the bar's hairline.
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LandingHero(
                  onSignIn: () => _openAuth(context, isLogin: true),
                ),
                const SizedBox(height: kLandingSectionGap),
                PageContainer(
                  maxWidth: kLandingContentWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LandingSectionTitle(title: l10n.landingFeaturesTitle),
                        const SizedBox(height: AppSpacing.xl),
                        const LandingFeatureGrid(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: kLandingSectionGap),
                PageContainer(
                  maxWidth: kLandingContentWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg),
                    child: LandingSectionTitle(
                      title: l10n.landingDestinationsTitle,
                      subtitle: l10n.landingDestinationsSubtitle,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                // Full-bleed: the rail aligns its first card with the content
                // column but scrolls edge-to-edge.
                const LandingDestinationRail(),
                const SizedBox(height: kLandingSectionGap),
                PageContainer(
                  maxWidth: kLandingContentWidth,
                  child: const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    child: LandingHowItWorks(),
                  ),
                ),
                const SizedBox(height: kLandingSectionGap),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: LandingCtaBand(
                    onGetStarted: () => _openAuth(context, isLogin: false),
                    onSignIn: () => _openAuth(context, isLogin: true),
                  ),
                ),
                const SizedBox(height: kLandingSectionGap),
                const LandingFooter(),
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
