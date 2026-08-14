import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/import_trip_screen.dart';
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

/// Push [page] onto the currently-selected tab's navigator, so the content area
/// animates while the persistent rail/bar stays put. Pass [location] when the
/// page is restorable from a URL (see [locatedRoute]).
void pushOnActiveTab(WidgetRef ref, Widget page, {String? location}) {
  final keys = ref.read(tabNavKeysProvider);
  final state = keys[ref.read(navIndexProvider)].currentState;
  state?.push(location == null
      ? MaterialPageRoute(builder: (_) => page)
      : locatedRoute(page, location));
}

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
  if (isActive || !_stackKeepingTabs.contains(AppTab.values[index])) {
    // Pop before switching: TabUrlObserver didPop bookkeeping (url_sync.dart)
    // drains while the old tab is still current, so the only URL report is
    // the destination tab's root.
    ref
        .read(tabNavKeysProvider)[index]
        .currentState
        ?.popUntil((r) => r.isFirst);
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
/// back lands on the trips list. Pops the Trips stack to root inside the
/// (possibly retried) push action — not eagerly — so a previously-open detail
/// doesn't sit underneath, and the reset happens next to the push that lands.
void openTripOnTripsTab(WidgetRef ref, String tripId) {
  ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
  final navKeys = ref.read(tabNavKeysProvider);
  pushOnTabWhenReady(navKeys, AppTab.trips, () {
    navKeys[AppTab.trips.index].currentState?.popUntil((r) => r.isFirst);
    return locatedRoute(
        TripDetailScreen(tripId: tripId), tripDetailLocation(tripId));
  });
}

/// Open the import-from-AI-chat screen on the Trips tab — every entry point
/// funnels here so the Trips nav item highlights, back lands on the trips
/// list, and the URL reports /import (whose refresh restores onto Trips).
/// The import screen's success replace-navigates to the new trip's detail,
/// which must land on the stack-keeping Trips tab, not whichever tab hosted
/// the entry point.
void openImportOnTripsTab(WidgetRef ref) {
  ref.read(navIndexProvider.notifier).state = AppTab.trips.index;
  final navKeys = ref.read(tabNavKeysProvider);
  pushOnTabWhenReady(navKeys, AppTab.trips, () {
    navKeys[AppTab.trips.index].currentState?.popUntil((r) => r.isFirst);
    return locatedRoute(
        const ImportTripScreen(), utilityLocation(BootUtility.importTrip));
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
