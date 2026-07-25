import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/analytics_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../widgets/brand_logo.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/language_menu_button.dart';
import '../widgets/legal_links.dart';
import '../widgets/page_container.dart';
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthScreen(initialIsLogin: isLogin),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      appBar: GradientAppBar(
        centerTitle: false,
        title: const BrandBadge(
          padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          child: BrandLogo.mark(size: 30),
        ),
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

                Text(
                  l10n.landingFeaturesTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),

                const SizedBox(height: AppSpacing.md),

                _FeatureCard(
                  icon: Icons.auto_awesome,
                  title: l10n.landingFeatureAgentTitle,
                  description: l10n.landingFeatureAgentDescription,
                ),

                const SizedBox(height: AppSpacing.xl),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => _openAuth(context, isLogin: false),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(
                      l10n.landingGetStarted,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
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
            TextButton(
              onPressed: openPrivacyPolicy,
              child: Text(l10n.landingPrivacyPolicy),
            ),
            Text('·', style: muted),
            TextButton(
              onPressed: openTermsOfService,
              child: Text(l10n.landingTermsOfService),
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
            Positioned.fill(
              child: Image.asset(
                'assets/images/hero_santorini.jpg',
                fit: BoxFit.cover,
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: AppColors.heroScrim),
              ),
            ),
            Container(
              constraints: const BoxConstraints(minHeight: 440),
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BrandBadge(
                    padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                    child: BrandLogo.lockup(height: 132),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.landingHeroTagline,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.landingHeroSubtitle,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onGetStarted,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.teal.shade800,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.landingGetStarted,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: onSignIn,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
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
      elevation: 1,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: accent, size: 26),
            ),
            const SizedBox(width: 16),
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
