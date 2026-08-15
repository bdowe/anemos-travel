import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../providers/analytics_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../widgets/brand_logo.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/language_menu_button.dart';
import '../widgets/legal_links.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import 'auth_screen.dart';

/// Marketing entry point shown to logged-out visitors. Brands the product and
/// showcases the core features, then funnels into the existing auth form:
/// "Get started" opens sign-up, "Sign in" opens login. On success the AuthGate
/// swaps this screen for the app automatically.
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

    return Scaffold(
      appBar: GradientAppBar(
        // No page title: the landing page's title is the brand. The bar's own
        // lockup (plated mark + wordmark) comes from GradientAppBar — this
        // screen sits outside the shell, so it keeps the mark at every width.
        actions: [
          const LanguageMenuButton(),
          TextButton(
            onPressed: () => _openAuth(context, isLogin: true),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: Text(l10n.landingSignIn),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: PageContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: AppSpacing.sm),
                _LandingHero(
                  onGetStarted: () => _openAuth(context, isLogin: false),
                  onSignIn: () => _openAuth(context, isLogin: true),
                ),
                const SizedBox(height: AppSpacing.xl + AppSpacing.xs),
                SectionHeader(title: l10n.landingFeaturesTitle),
                const SizedBox(height: AppSpacing.md),
                _FeatureCard(
                  icon: Icons.auto_awesome,
                  title: l10n.landingFeatureAgentTitle,
                  description: l10n.landingFeatureAgentDescription,
                ),
                const SizedBox(height: AppSpacing.lg),
                const _LandingFooter(),
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Footer: legal links + company line, so the policy pages are reachable
/// before sign-up (affiliate programs require a discoverable privacy policy).
class _LandingFooter extends StatelessWidget {
  const _LandingFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          children: [
            // Shared legal strings + open helpers from legal_links.dart, so
            // the footer and the auth screen can never drift apart.
            TextButton(
              onPressed: openPrivacyPolicy,
              child: Text(l10n.legalPrivacyPolicy),
            ),
            Text('·', style: muted),
            TextButton(
              onPressed: openTermsOfService,
              child: Text(l10n.legalTermsOfService),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(l10n.landingCopyright, style: muted),
      ],
    );
  }
}

/// Branded hero: full-bleed photo, teal scrim, tagline, and the primary CTAs.
/// Mirrors the home screen's `_AgentHeroCard` so the logged-out and logged-in
/// experiences read as one product.
class _LandingHero extends StatelessWidget {
  final VoidCallback onGetStarted;
  final VoidCallback onSignIn;

  const _LandingHero({required this.onGetStarted, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return LayoutBuilder(builder: (context, constraints) {
      // Compact metrics below ~600px so both CTAs stay above the fold even on
      // a 320x568 phone (the app's primary acquisition surface): smaller
      // lockup, tighter padding/minHeight, subtitle capped at three lines.
      final narrow = constraints.maxWidth < 600;
      return Container(
        decoration: BoxDecoration(
          borderRadius: AppRadius.lgAll,
          boxShadow: [
            BoxShadow(
              color: AppColors.brandDark.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: AppRadius.lgAll,
          child: Stack(
            children: [
              // Branded gradient behind the photo: visible until the image
              // decodes and whenever it fails to load, so the white hero copy
              // and CTAs always sit on a dark branded surface.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(gradient: AppColors.brandGradient),
                ),
              ),
              Positioned.fill(
                child: Image.asset(
                  'assets/images/hero_santorini.jpg',
                  fit: BoxFit.cover,
                  // Decorative: the tagline below carries the message.
                  excludeFromSemantics: true,
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: child,
                    );
                  },
                  // The gradient underneath is the fallback.
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(gradient: AppColors.heroScrim),
                ),
              ),
              Container(
                constraints: BoxConstraints(minHeight: narrow ? 360 : 440),
                padding: EdgeInsets.all(
                    narrow ? AppSpacing.xl : AppSpacing.xl + AppSpacing.xs),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Bare mark + white wordmark floating on the scrimmed
                    // photo, matching the auth screen's plateless mark. The
                    // lockup PNG's baked-in charcoal wordmark needed the
                    // white badge plate; white Cinzel text does not.
                    BrandLogo.mark(size: narrow ? 52 : 96),
                    const SizedBox(height: AppSpacing.sm),
                    ExcludeSemantics(
                      // The mark's Image already carries the "Anemos"
                      // semantic label.
                      child: BrandWordmark(
                        fontSize: narrow ? 24 : 40,
                        // Caps run wide, so tracking opens up with the size.
                        letterSpacing: 1.5,
                        height: 1.1,
                        color: Colors.white,
                        // Guards the scrim's lighter top-right corner
                        // (alpha 0.35) against bright photo patches.
                        shadows: const [
                          Shadow(
                              color: Colors.black26,
                              blurRadius: 8,
                              offset: Offset(0, 2)),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      l10n.landingHeroTagline,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      l10n.landingHeroSubtitle,
                      maxLines: narrow ? 3 : null,
                      overflow: narrow ? TextOverflow.ellipsis : null,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: onGetStarted,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.brandDark,
                          padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.lg),
                          shape: const RoundedRectangleBorder(
                            borderRadius: AppRadius.mdAll,
                          ),
                        ),
                        child: Text(
                          l10n.landingGetStarted,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: onSignIn,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.md),
                        ),
                        child: Text(l10n.landingHaveAccount),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// Informational feature row: colored icon chip + title + description (these
/// don't navigate).
class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.brand;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: AppRadius.smAll,
              ),
              child: Icon(icon, color: accent, size: 26),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
