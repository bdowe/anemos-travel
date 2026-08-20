import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/import_trip_screen.dart';
import '../screens/log_trip_screen.dart';
import '../screens/travel_atlas_screen.dart';
import '../screens/trip_detail_screen.dart';
import 'app_routes.dart';

/// Top-level destinations. Keeping it to three keeps the choice trivial
/// (Hick's Law) and puts the chat and saved trips one tap away instead of
/// buried in a menu.
enum AppTab { home, plan, trips }

/// The selected top-level tab. A provider (rather than local state) so any
/// screen — e.g. the home hero, or a pushed page's nav rail — can switch tabs
/// without prop-drilling callbacks.
final navIndexProvider = StateProvider<int>((ref) => AppTab.home.index);

/// One navigator key per tab, created once for the app's lifetime. Shared (via a
/// provider, not held privately by the shell) so utility actions rendered
/// *outside* the tab navigators — e.g. the nav rail's account menu — can push
/// onto the active tab's navigator instead of the root, keeping the rail in
/// place.
final tabNavKeysProvider = Provider<List<GlobalKey<NavigatorState>>>(
  (ref) => List.generate(AppTab.values.length, (_) => GlobalKey<NavigatorState>()),
);

/// A [MaterialPageRoute] whose settings name is the page's location in the
/// URL grammar (app_routes.dart), which makes it visible to URL sync: the
/// address bar shows [location] while the route is on top, and a refresh
/// there restores the page. Pushes without a location keep the URL of the
/// page beneath them.
Route<T> locatedRoute<T>(Widget page, String location) => MaterialPageRoute<T>(
      settings: RouteSettings(name: location),
      builder: (_) => page,
    );

/// [locatedRoute]'s sibling for navigation the user never performed as a
/// gesture — restoring a page from the URL, or a jump that also switches tabs
/// (where the tab switch *is* the transition). The page is simply there.
///
/// A separate name rather than a flag on [locatedRoute] so which kind of
/// navigation a call site performs is visible at the call site.
Route<T> instantRoute<T>(Widget page, String location) => _InstantPageRoute<T>(
      settings: RouteSettings(name: location),
      builder: (_) => page,
    );

/// A page that arrives with no transition. Overrides ONLY [transitionDuration]
/// — [reverseTransitionDuration] stays the platform's, so backing out of the
/// page animates like any other pop. (MaterialRouteTransitionMixin re-applies
/// each onto the controller in didPush/didPop, so overriding the getter holds.)
class _InstantPageRoute<T> extends MaterialPageRoute<T> {
  _InstantPageRoute({required super.builder, super.settings});

  @override
  Duration get transitionDuration => Duration.zero;
}

/// [nav]'s topmost route, **without popping anything**: [NavigatorState]
/// exposes no stack getter, but [NavigatorState.popUntil] hands its predicate
/// the top route and returns having popped nothing when the predicate answers
/// true. This is a peek — the `true` is load-bearing, not a placeholder.
Route<dynamic>? _topRouteOf(NavigatorState nav) {
  Route<dynamic>? top;
  nav.popUntil((route) {
    top = route;
    return true;
  });
  return top;
}

/// Clear [nav] back to its root with NO transition.
///
/// A stack reset is bookkeeping, not a gesture: the user asked for the
/// destination, never to watch the page they left behind slide away. It also
/// cannot be *popped* from here — the shell freezes hidden tabs' tickers
/// (app_shell.dart), so a pop started on a tab that is about to be revealed
/// parks fully painted and then plays its whole exit transition in the user's
/// face. [NavigatorState.removeRoute] takes each route out immediately
/// instead, and still reports didRemove — the same bookkeeping TabUrlObserver
/// already does for didPop (url_sync.dart), so this is URL-transparent.
void resetToRoot(NavigatorState? nav) {
  if (nav == null) return;
  // Bounded only so that no future SDK change can turn this into a hung
  // frame; removeRoute always shortens the stack, so the guard never trips.
  for (var i = 0; i < 50; i++) {
    final top = _topRouteOf(nav);
    if (top == null || top.isFirst) return;
    nav.removeRoute(top);
  }
}

/// Push [page] onto the currently-selected tab's navigator, so the content area
/// animates while the persistent rail/bar stays put. Pass [location] when the
/// page is restorable from a URL (see [locatedRoute]).
///
/// No double-tap guard here: [isTopRoute] answers about the CALLER's route,
/// which this helper cannot see — and its main caller, the rail account menu,
/// renders outside the tab navigators entirely, so the answer would be about
/// the wrong navigator. Callers that live on the tab's top route (the
/// notification card) guard themselves; menu items need no guard because
/// selecting one dismisses the menu.
void pushOnActiveTab(WidgetRef ref, Widget page, {String? location}) {
  final keys = ref.read(tabNavKeysProvider);
  final state = keys[ref.read(navIndexProvider)].currentState;
  state?.push(location == null
      ? MaterialPageRoute(builder: (_) => page)
      : locatedRoute(page, location));
}

/// Whether [context]'s route is still the one on top of its navigator — i.e.
/// nothing has been pushed since the tap now being handled.
///
/// **This is the double-tap guard.** Nothing in this app debounces taps, and
/// [NavigatorState.push] flushes its history synchronously, so a second tap
/// already sees the button's own route stop being current. Two pushes leave a
/// duplicate screen stacked under an opaque one — invisible until "back"
/// returns you to the page you were already looking at.
///
/// Flutter half-covers this itself and says so: `_cancelActivePointers`
/// (navigator.dart) flips the navigator's AbsorbPointer on when a route
/// changes between frames, under a comment reading "This mechanism is far from
/// perfect" (flutter#4770). It only holds for the rest of that inter-frame
/// gap — it does nothing for a handler that pushes **after an await**, which
/// is the reachable case here (see `_signIn` in connect_app_screen.dart, where
/// the second call would also wipe the pending token the first one saved), nor
/// for a push issued from inside a frame.
///
/// Answers about [context]'s OWN navigator, so it cannot see a push onto a
/// different one (a `rootNavigator: true` push from inside a tab — see
/// `_openFullMap` in trip_detail_screen.dart, which guards on the root
/// navigator directly). Fails open when there is no route at all: a missing
/// guard must never be able to block navigation outright.
bool isTopRoute(BuildContext context) =>
    ModalRoute.of(context)?.isCurrent ?? true;

/// Push [route] onto [context]'s navigator unless a push already landed
/// ([isTopRoute]) — in which case nothing happens and the future completes
/// with null.
///
/// Handlers that do more than push — cleanup after the await, a refetch, a
/// saved token to clear — must test [isTopRoute] and return early themselves
/// instead, so that trailing work is skipped too rather than running against
/// the navigation the first tap started.
Future<T?> pushOnce<T extends Object?>(BuildContext context, Route<T> route) =>
    isTopRoute(context)
        ? Navigator.of(context).push(route)
        : Future<T?>.value();

/// Tabs whose pushed stack survives switching away and back via a nav
/// button: selecting the tab returns you to where you left it (e.g. the trip
/// you were viewing); selecting it again pops to its root. Every other tab
/// always lands on its root. Only Trips earns this: a trip is a workspace
/// you step out of and back into, while Home and Plan are destinations.
const Set<AppTab> _stackKeepingTabs = {AppTab.trips};

/// Select a top-level tab the way a nav button does. Destinations outside
/// [_stackKeepingTabs] are reset to their root — those nav buttons always go
/// to the page they name — and a re-tap of the active tab pops to root
/// everywhere. Programmatic switch+push flows (Home trip cards, boot
/// restore, shared-trip join) write [navIndexProvider] directly instead, so
/// their pushes survive.
void selectTab(WidgetRef ref, int index) {
  final isActive = ref.read(navIndexProvider) == index;
  final nav = ref.read(tabNavKeysProvider)[index].currentState;
  if (isActive) {
    // Re-tapping the tab you are already on IS the gesture, and it happens on
    // a tab you can see — so this one pops, and animates, like any other back.
    nav?.popUntil((r) => r.isFirst);
  } else if (!_stackKeepingTabs.contains(AppTab.values[index])) {
    // Remove rather than pop, and before switching. Remove because the
    // destination tab is still hidden: a pop would freeze mid-flight and then
    // replay in full the moment the IndexedStack reveals it ([resetToRoot]).
    // Before, because TabUrlObserver's bookkeeping (url_sync.dart) then drains
    // while the old tab is still current, so the only URL report is the
    // destination tab's root — the stale page's location never reaches the
    // address bar.
    resetToRoot(nav);
  }
  if (!isActive) {
    ref.read(navIndexProvider.notifier).state = index;
  }
}

/// Return to the Home tab — the logo-tap action.
void goHome(WidgetRef ref) => selectTab(ref, AppTab.home.index);

/// Push a route onto [tab]'s navigator, retrying across frames while the
/// nested navigator mounts (cold boot, shell remount after a root reset). If
/// every attempt misses, the user still lands on the selected tab's root.
/// Takes the keys — not a ref — so callers whose element is about to be
/// disposed (shared-trip join) capture them up front, and the Ref-holding
/// UrlSyncController can share it.
void pushOnTabWhenReady(List<GlobalKey<NavigatorState>> navKeys, AppTab tab,
    Route<dynamic> Function() buildRoute,
    [int attempts = 10]) {
  final nav = navKeys[tab.index].currentState;
  if (nav != null) {
    nav.push(buildRoute());
  } else if (attempts > 0) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => pushOnTabWhenReady(navKeys, tab, buildRoute, attempts - 1));
  }
}

/// Open [tripId]'s detail on the Trips tab: the Trips nav item highlights and
/// the trips list sits underneath. Resets the Trips stack inside the (possibly
/// retried) push action — not eagerly — so a previously-open detail doesn't
/// sit underneath, and the reset happens next to the push that lands.
///
/// Both steps are instant. The tab switch is already the transition, and both
/// run while the Trips tab is still hidden, so an animated reset+push would
/// freeze and then replay together — the trip you had open sliding out from
/// under the one you just asked for.
///
/// [from] is the tab the traveler is standing on, and only Home's trip cards
/// pass it: the detail still lives on the Trips tab, but back returns them to
/// Home rather than to a trips list they never opened. It rides the ROUTE (see
/// [TripDetailScreen.entryOrigin]) rather than a provider, so it cannot outlive
/// the screen it describes. Passing nothing — or [AppTab.trips] — is the
/// behavior every caller had before.
void openTripOnTripsTab(WidgetRef ref, String tripId, {AppTab? from}) {
  ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
  final navKeys = ref.read(tabNavKeysProvider);
  pushOnTabWhenReady(navKeys, AppTab.trips, () {
    resetToRoot(navKeys[AppTab.trips.index].currentState);
    return instantRoute(
        TripDetailScreen(tripId: tripId, entryOrigin: from),
        tripDetailLocation(tripId));
  });
}

/// Open the import-from-AI-chat screen on the Trips tab — every entry point
/// funnels here so the Trips nav item highlights, back lands on the trips
/// list, and the URL reports /import (whose refresh restores onto Trips).
/// The import screen's success replace-navigates to the new trip's detail,
/// which must land on the stack-keeping Trips tab, not whichever tab hosted
/// the entry point. Instant for the same reason as [openTripOnTripsTab].
void openImportOnTripsTab(WidgetRef ref) {
  ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
  final navKeys = ref.read(tabNavKeysProvider);
  pushOnTabWhenReady(navKeys, AppTab.trips, () {
    resetToRoot(navKeys[AppTab.trips.index].currentState);
    return instantRoute(
        const ImportTripScreen(), utilityLocation(BootUtility.importTrip));
  });
}

/// Open the log-a-past-trip screen on the Trips tab (specs/log-past-trip). The
/// import twin above, and for the same reasons: the screen's success
/// replace-navigates to the new trip's detail, which has to land on the
/// stack-keeping Trips tab rather than whichever tab the entry point sat on —
/// and this one has three entry points, so funnelling them is not optional.
void openLogTripOnTripsTab(WidgetRef ref) {
  ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
  final navKeys = ref.read(tabNavKeysProvider);
  pushOnTabWhenReady(navKeys, AppTab.trips, () {
    navKeys[AppTab.trips.index].currentState?.popUntil((r) => r.isFirst);
    return locatedRoute(
        const LogTripScreen(), utilityLocation(BootUtility.logTrip));
  });
}

/// Open the travel atlas on the Trips tab — the "See all" destination of the
/// trips list's "Your travels" section. The [openLogTripOnTripsTab] shape:
/// same tab, same pop-to-root, and a [locatedRoute] rather than an
/// [instantRoute] because its one entry point sits ON the Trips tab, so the
/// push IS the transition the user asked for.
///
/// Funnelled through a helper anyway, for the reason its twin was: a screen
/// pushed from the wrong tab strands its back button on the wrong list.
void openAtlasOnTripsTab(WidgetRef ref) {
  ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
  final navKeys = ref.read(tabNavKeysProvider);
  pushOnTabWhenReady(navKeys, AppTab.trips, () {
    navKeys[AppTab.trips.index].currentState?.popUntil((r) => r.isFirst);
    return locatedRoute(
        const TravelAtlasScreen(), utilityLocation(BootUtility.travelAtlas));
  });
}

/// One nav destination's icons. Shared so the shell's rail and bar render the
/// exact same set, in lockstep. Labels are NOT here: they are localized and
/// resolved from [AppTab] in the shell (specs/i18n-spanish), so there is one
/// source of truth rather than an English copy that silently drifts.
class NavDestinationData {
  final IconData icon;
  final IconData selectedIcon;

  const NavDestinationData({
    required this.icon,
    required this.selectedIcon,
  });
}

/// The single source of truth for the three top-level destinations, ordered to
/// match [AppTab].
const List<NavDestinationData> navDestinations = [
  NavDestinationData(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
  ),
  NavDestinationData(
    icon: Icons.auto_awesome_outlined,
    selectedIcon: Icons.auto_awesome,
  ),
  NavDestinationData(
    icon: Icons.luggage_outlined,
    selectedIcon: Icons.luggage,
  ),
];

/// Width at or above which the persistent rail (rather than a bottom bar) is
/// shown.
const double kRailBreakpoint = 800;
