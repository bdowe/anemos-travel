import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'constants/app_info.dart';
import 'l10n/l10n.dart';
import 'navigation/app_routes.dart';
import 'navigation/url_sync.dart';
import 'providers/auth_provider.dart';
import 'providers/locale_provider.dart';
import 'theme/app_theme.dart';
import 'screens/connect_app_screen.dart';
import 'screens/landing_screen.dart';
import 'screens/app_shell.dart';
import 'screens/onboarding_quiz_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/shared_trip_screen.dart';
import 'screens/sso_callback_screen.dart';
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
///
/// isBoot marks this the cold-boot route: the only one allowed to carry a
/// restore target (specs/url-page-persistence) — runtime pushNamed('/')
/// resets must never replay the boot URL's destination.
List<Route<dynamic>> generateInitialRoutes(String initialRoute) =>
    [generateRoute(RouteSettings(name: initialRoute), isBoot: true)];

/// Route by URL so share links work signed-out. Everything else lands
/// on AuthGate, preserving the existing splash -> landing/quiz/shell
/// flow. Legacy /#/share links are rewritten by the index.html shim.
Route<dynamic> generateRoute(RouteSettings settings, {bool isBoot = false}) {
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
  // URL persistence (specs/url-page-persistence): recognized app paths —
  // tabs, /trips/<id> (and the connector's /trip/<id> alias), the utility
  // screens, /plan/<chatId> — land on the normal gate carrying
  // a parsed target that URL sync applies once the session resolves, so the
  // page boots inside the shell. Unknown paths parse to null and behave like
  // the plain catch-all.
  final target = uri == null ? null : parseBootTarget(uri);
  return MaterialPageRoute(
    settings: settings,
    builder: (_) => AuthGate(bootTarget: isBoot ? target : null),
  );
}

class TravelRoutePlannerApp extends ConsumerWidget {
  const TravelRoutePlannerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching only the locale the widget layer needs, not the whole state.
    final locale = ref.watch(localeProvider.select((s) => s.materialLocale));
    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      // specs/i18n-spanish. Always concrete: the locale provider resolves the
      // device language itself and stores it at first launch.
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
      // URL persistence write half: re-asserts the synced location after
      // root-navigator events (specs/url-page-persistence).
      navigatorObservers: [ref.watch(rootUrlObserverProvider)],
    );
  }
}

/// Shows a loading splash until the stored session is checked, then routes to
/// the landing page (signed out), the one-time signup quiz (signed in but not
/// yet onboarded), or the home screen.
class AuthGate extends ConsumerStatefulWidget {
  /// Where the boot URL pointed (specs/url-page-persistence); null everywhere
  /// but the cold-boot route. URL sync holds it until the session resolves
  /// signed-in-and-onboarded, so it survives the landing page and the quiz.
  final BootTarget? bootTarget;

  const AuthGate({super.key, this.bootTarget});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  @override
  void initState() {
    super.initState();
    // A plain field hand-off (no provider writes — illegal in initState).
    ref.read(urlSyncProvider).registerBootTarget(widget.bootTarget);
  }

  @override
  Widget build(BuildContext context) {
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
      duration: const Duration(milliseconds: 120),
      child: child,
    );
  }
}