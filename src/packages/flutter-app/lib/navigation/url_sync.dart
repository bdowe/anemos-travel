import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/plan_provider.dart';
import '../providers/plan_resume.dart';
import '../providers/resumable_chats_provider.dart';
import '../screens/account_settings_screen.dart';
import '../screens/admin_metrics_screen.dart';
import '../screens/alerts_screen.dart';
import '../screens/guides_screen.dart';
import '../screens/import_trip_screen.dart';
import '../screens/local_admin_screen.dart';
import '../screens/notification_center_screen.dart';
import '../screens/preferences_screen.dart';
import '../screens/trip_detail_screen.dart';
import 'app_nav.dart';
import 'app_routes.dart';

/// URL persistence (specs/url-page-persistence): keeps the browser address bar
/// in sync with the page on screen so a refresh restores it.
///
/// The app stays on Navigator 1.0, so nothing reports the URL after boot by
/// itself — [UrlSyncController] derives the current location from the active
/// tab and that tab's topmost *named* route (observers below), and writes it
/// via [SystemNavigator.routeInformationUpdated]. The engine is in
/// single-entry history mode (the WidgetsApp default), where that call
/// REPLACES the browser entry: the URL updates without growing a history
/// stack, and the back button keeps its existing pop behavior.
///
/// The read half lives in main.dart's generateRoute: recognized paths parse to
/// a [BootTarget] (lib/navigation/app_routes.dart) that AuthGate registers
/// here; [_onAuthChanged] consumes it once the session resolves signed-in.

/// Writes one location to the address bar. A provider so tests can record
/// reports instead; also the single seam to touch if an SDK upgrade changes
/// the engine call.
typedef UrlReporter = void Function(String location);

final urlReporterProvider = Provider<UrlReporter>((ref) => _reportToEngine);

void _reportToEngine(String location) {
  if (!kIsWeb) return;
  SystemNavigator.routeInformationUpdated(
      uri: Uri.parse(location), replace: true);
}

final urlSyncProvider = Provider<UrlSyncController>((ref) {
  final controller = UrlSyncController(ref);
  ref.listen(navIndexProvider, (_, __) => controller._report());
  // The plan tab's root location includes the conversation id once one
  // exists (first send / resume; cleared by Start over).
  ref.listen(planProvider.select((s) => s.chatId),
      (_, __) => controller._report());
  ref.listen(authProvider, controller._onAuthChanged);
  return controller;
});

/// Root-navigator observer, attached via MaterialApp.navigatorObservers.
/// Created through a provider so the controller exists from the first frame.
final rootUrlObserverProvider = Provider<RootUrlObserver>(
    (ref) => RootUrlObserver(ref.watch(urlSyncProvider)));

class UrlSyncController {
  UrlSyncController(this._ref);

  final Ref _ref;

  /// Named routes above each tab's root, oldest first. Holds [Route]
  /// references rather than name strings so a pop removes exactly its own
  /// entry even if two routes on the stack share a name.
  final List<List<Route<dynamic>>> _tabStacks =
      List.generate(AppTab.values.length, (_) => <Route<dynamic>>[]);

  /// False until a tab-root route mounts. Gates every report so bare-boot
  /// flows (/share, /sso, /connect, …) never have their URL touched, and so
  /// nothing reports while the splash/landing screens are up.
  bool _shellAttached = false;

  String? _lastReported;

  BootTarget? _bootTarget;
  bool _bootConsumed = false;

  // ---- write half -------------------------------------------------------

  String get _currentLocation {
    final tab = _ref.read(navIndexProvider);
    final stack = _tabStacks[tab];
    if (stack.isNotEmpty) return stack.last.settings.name!;
    return _tabRootLocation(AppTab.values[tab]);
  }

  String _tabRootLocation(AppTab tab) => switch (tab) {
        AppTab.home => kHomeLocation,
        // The root planProvider only — trip-bound panel chats
        // (tripRefineProvider) never reach the URL.
        AppTab.plan => switch (_ref.read(planProvider).chatId) {
            null => kPlanLocation,
            final chatId => planChatLocation(chatId),
          },
        AppTab.trips => kTripsLocation,
      };

  void _report() {
    if (!_shellAttached) return;
    final location = _currentLocation;
    if (location == _lastReported) return;
    _lastReported = location;
    _ref.read(urlReporterProvider)(location);
  }

  void _didPushOnTab(int tab, Route<dynamic> route) {
    if (route.isFirst) {
      // A tab root mounting (first shell build, or a remount after a
      // pushNamedAndRemoveUntil('/') reset recreated the navigator): any
      // remembered stack belonged to the dead navigator.
      _tabStacks[tab].clear();
      _shellAttached = true;
    } else if (route.settings.name != null) {
      _tabStacks[tab].add(route);
    }
    _report();
  }

  void _didRemoveFromTab(int tab, Route<dynamic> route) {
    _tabStacks[tab].remove(route);
    _report();
  }

  void _didReplaceOnTab(
      int tab, Route<dynamic>? newRoute, Route<dynamic>? oldRoute) {
    if (oldRoute != null) _tabStacks[tab].remove(oldRoute);
    if (newRoute != null && !newRoute.isFirst && newRoute.settings.name != null) {
      _tabStacks[tab].add(newRoute);
    }
    _report();
  }

  /// After any ROOT-navigator event, re-assert our location a frame later.
  /// The framework auto-reports named root routes (the five
  /// pushNamedAndRemoveUntil('/') reset sites report `/`), which would
  /// otherwise be the last word in the address bar even though the shell
  /// remounts on some tab. Unconditional on purpose: it must out-shout the
  /// framework's report, so it skips the [_lastReported] dedupe.
  void _reassertAfterRootNavigation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_shellAttached) return;
      final location = _currentLocation;
      _lastReported = location;
      _ref.read(urlReporterProvider)(location);
    });
  }

  // ---- read half (boot restore) -----------------------------------------

  /// Called by AuthGate. Only the boot route carries a non-null target
  /// (generateRoute's isBoot flag), so runtime resets to '/' can never
  /// clobber a flow's chosen tab; nulls are ignored here for the same reason.
  void registerBootTarget(BootTarget? target) {
    if (target == null || _bootTarget != null || _bootConsumed) return;
    _bootTarget = target;
    // AuthGate registers from initState (build phase, where provider writes
    // are illegal); check outside the frame. The normal path — auth still
    // restoring — is handled by _onAuthChanged when it resolves.
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _maybeConsumeBootTarget(_ref.read(authProvider)));
  }

  void _onAuthChanged(AuthState? previous, AuthState next) {
    if ((previous?.isSignedIn ?? false) && !next.isSignedIn) {
      // Sign-out: the shell is unmounting (no observer events fire for
      // that), so forget its stacks and hand the address bar back to root.
      for (final stack in _tabStacks) {
        stack.clear();
      }
      _shellAttached = false;
      if (_lastReported != kHomeLocation) {
        _lastReported = kHomeLocation;
        _ref.read(urlReporterProvider)(kHomeLocation);
      }
    }
    _maybeConsumeBootTarget(next);
  }

  /// Applies the boot target once the session is signed in and onboarded —
  /// which also covers "sign in later, then land where the URL pointed" and
  /// "finish the quiz, then land". Consumed at most once per app run so a
  /// sign-out/sign-in cycle doesn't replay a stale deep link.
  void _maybeConsumeBootTarget(AuthState auth) {
    final target = _bootTarget;
    if (target == null || _bootConsumed) return;
    if (!auth.initialized || !auth.isSignedIn) return;
    if (auth.user!.needsOnboarding) return;
    _bootConsumed = true;
    _bootTarget = null;

    // Listener context, never mid-build: the provider write is legal, and it
    // lands before the frame that mounts AppShell — no wrong-tab flash.
    _ref.read(navIndexProvider.notifier).state = target.tab.index;

    final tripId = target.tripId;
    final utility = target.utility;
    final chatId = target.chatId;
    final navKeys = _ref.read(tabNavKeysProvider);
    if (tripId != null) {
      pushOnTabWhenReady(
          navKeys,
          target.tab,
          () => locatedRoute(
              TripDetailScreen(tripId: tripId), tripDetailLocation(tripId)));
    } else if (utility != null) {
      pushOnTabWhenReady(navKeys, target.tab,
          () => locatedRoute(_utilityScreen(utility), utilityLocation(utility)));
    } else if (chatId != null) {
      // Fire-and-forget: success rehydrates planProvider (the Plan tab —
      // already selected above — renders it, and the chatId listener restores
      // /plan/<id> in the address bar); failure — no stored transcript, e.g.
      // a trip-bound or foreign id — silently leaves a fresh chat at /plan.
      resumePlanChat(
        chats: _ref.read(chatsApiServiceProvider),
        plan: _ref.read(planProvider.notifier),
        chatId: chatId,
      );
    }
  }

  Widget _utilityScreen(BootUtility utility) => switch (utility) {
        BootUtility.alerts => const AlertsScreen(),
        BootUtility.preferences => const PreferencesScreen(),
        BootUtility.account => const AccountSettingsScreen(),
        BootUtility.adminMetrics => const AdminMetricsScreen(),
        BootUtility.adminLocal => const LocalAdminScreen(),
        BootUtility.importTrip => const ImportTripScreen(),
        BootUtility.guides => const GuidesScreen(),
        BootUtility.notifications => const NotificationCenterScreen(),
      };
}

/// Forwards one tab navigator's route events to the controller. Instances are
/// created fresh in every AppShell build: a NavigatorObserver may only be
/// attached to one navigator at a time, and app-lifetime instances would
/// trip that assert when a reset remounts the shell.
class TabUrlObserver extends NavigatorObserver {
  TabUrlObserver(this._controller, this._tab);

  final UrlSyncController _controller;
  final int _tab;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _controller._didPushOnTab(_tab, route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _controller._didRemoveFromTab(_tab, route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _controller._didRemoveFromTab(_tab, route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _controller._didReplaceOnTab(_tab, newRoute, oldRoute);
}

/// Watches the ROOT navigator only to re-assert the synced location after
/// its pushes/pops (see [UrlSyncController._reassertAfterRootNavigation]).
class RootUrlObserver extends NavigatorObserver {
  RootUrlObserver(this._controller);

  final UrlSyncController _controller;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _controller._reassertAfterRootNavigation();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _controller._reassertAfterRootNavigation();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _controller._reassertAfterRootNavigation();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _controller._reassertAfterRootNavigation();
}
