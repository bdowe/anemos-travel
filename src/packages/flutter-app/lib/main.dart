import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'constants/app_info.dart';
import 'l10n/l10n.dart';
import 'providers/auth_provider.dart';
import 'providers/locale_provider.dart';
import 'theme/app_theme.dart';
import 'screens/alerts_screen.dart';
import 'screens/connect_app_screen.dart';
import 'screens/landing_screen.dart';
import 'screens/app_shell.dart';
import 'screens/onboarding_quiz_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/shared_trip_screen.dart';
import 'screens/sso_callback_screen.dart';
import 'screens/trip_detail_screen.dart';
import 'screens/verify_email_screen.dart';
import 'screens/splash_screen.dart';

void main() {
  // Path-style URLs on web (https://host/app/share/x instead of /#/share/x).
  // The engine strips the base href before routing, so onGenerateRoute sees
  // clean paths in both dev (/) and deployment (/app/). No-op off web.
  usePathUrlStrategy();
  runApp(
    const ProviderScope(
      child: TravelRoutePlannerApp(),
    ),
  );
}

/// A deep link boots on exactly its own route. The default
/// onGenerateInitialRoutes expands `/share/x` into a stack of every path
/// prefix (`/`, `/share`, `/share/x`); the prefixes hit the AuthGate
/// catch-all, so a signed-in session mounts two AppShells whose tab
/// navigators share the same GlobalKeys — the tree corrupts and the body
/// renders blank.
List<Route<dynamic>> generateInitialRoutes(String initialRoute) =>
    [generateRoute(RouteSettings(name: initialRoute))];

/// Route by URL so share links work signed-out. Everything else lands
/// on AuthGate, preserving the existing splash -> landing/quiz/shell
/// flow. Legacy /#/share links are rewritten by the index.html shim.
Route<dynamic> generateRoute(RouteSettings settings) {
  final uri = Uri.tryParse(settings.name ?? '/');
  final segments = uri?.pathSegments ?? const <String>[];
  if (segments.length == 2 && segments[0] == 'share') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => SharedTripScreen(token: segments[1]),
    );
  }
  // Emailed co-planner invites (specs/invite-by-email); same screen,
  // invite-token fetch + accept.
  if (segments.length == 2 && segments[0] == 'invite') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => SharedTripScreen(
          token: segments[1], linkKind: SharedLinkKind.invite),
    );
  }
  if (segments.length == 2 && segments[0] == 'reset') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => ResetPasswordScreen(token: segments[1]),
    );
  }
  if (segments.length == 2 && segments[0] == 'verify') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => VerifyEmailScreen(token: segments[1]),
    );
  }
  // Landing spot for the Google sign-in redirect (specs/google-sso):
  // /sso/<one-time code>, or /sso/error when the flow failed upstream.
  if (segments.length == 2 && segments[0] == 'sso') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => SsoCallbackScreen(code: segments[1]),
    );
  }
  // AI-connector consent (specs/mcp-connector): ChatGPT/claude.ai send the
  // browser to /connect/<request-token> during account linking. The screen
  // handles the signed-out case with its own sign-in step.
  if (segments.length == 2 && segments[0] == 'connect') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => ConnectAppScreen(requestToken: segments[1]),
    );
  }
  // A connector's create_trip returns a /trip/<id> URL so the AI's answer can
  // link straight into the app.
  if (segments.length == 2 && segments[0] == 'trip') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => TripDetailScreen(tripId: segments[1]),
    );
  }
  // Price-alert emails deep-link here; the screen itself handles the
  // signed-out case with a sign-in prompt.
  if (segments.length == 1 && segments[0] == 'alerts') {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => const AlertsScreen(),
    );
  }
  return MaterialPageRoute(
    settings: settings,
    builder: (_) => const AuthGate(),
  );
}

class TravelRoutePlannerApp extends ConsumerWidget {
  const TravelRoutePlannerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching only the locale the widget layer needs: a change to the stored
    // override alone (same effective language) must not rebuild the app.
    final locale = ref.watch(localeProvider.select((s) => s.materialLocale));
    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      // specs/i18n-spanish. `locale` is null while following the device, which
      // lets Flutter resolve against supportedLocales itself.
      locale: locale,
      supportedLocales: kSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateRoute: generateRoute,
      onGenerateInitialRoutes: generateInitialRoutes,
    );
  }
}

/// Shows a loading splash until the stored session is checked, then routes to
/// the landing page (signed out), the one-time signup quiz (signed in but not
/// yet onboarded), or the home screen.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final Widget child;
    if (!auth.initialized) {
      child = const SplashScreen();
    } else if (!auth.isSignedIn) {
      child = const LandingScreen();
    } else {
      child = auth.user!.needsOnboarding
          ? const OnboardingQuizScreen()
          : const AppShell();
    }
    // Fade between splash and destination so instant auth resolution isn't a
    // one-frame hard cut. Branches are distinct types, so no keys needed.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: child,
    );
  }
}