import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Return to the Home tab — the logo-tap action. Mirrors the shell's
/// tab-select behavior: already on Home pops its stack to the root, otherwise
/// the tab switches (keeping the other tab's stack intact for its next visit).
void goHome(WidgetRef ref) {
  if (ref.read(navIndexProvider) == AppTab.home.index) {
    final keys = ref.read(tabNavKeysProvider);
    keys[AppTab.home.index].currentState?.popUntil((r) => r.isFirst);
  } else {
    ref.read(navIndexProvider.notifier).state = AppTab.home.index;
  }
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
