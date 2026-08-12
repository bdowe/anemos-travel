import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/url_sync.dart';
import '../theme/spacing.dart';
import '../widgets/account_menu.dart';
import '../widgets/brand_logo.dart';
import 'home_screen.dart';
import 'agent_screen.dart';
import 'trips_list_screen.dart';

/// Persistent navigation shell. The rail (wide) / bar (narrow) lives here,
/// outside the per-tab navigators, so it never moves when a page is pushed —
/// only the content area animates. Each tab has its own push stack; nav-button
/// behavior is [selectTab]'s contract: Home (and Plan) always land on their
/// root, while Trips keeps your place — first tap returns to the trip you
/// were viewing, a second tap pops to the list. Programmatic switch+push
/// flows (Home trip cards, boot restore, shared-trip join) write
/// [navIndexProvider] directly, so their pushes survive regardless.
///
/// [navDestinations] carries the icons and ordering; its labels are display
/// copy, so the shell renders the localized label for each tab instead
/// (specs/i18n-spanish).
String _destinationLabel(AppLocalizations l10n, int index) =>
    switch (AppTab.values[index]) {
      AppTab.home => l10n.shellNavHome,
      AppTab.plan => l10n.shellNavPlan,
      AppTab.trips => l10n.shellNavTrips,
    };

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final index = ref.watch(navIndexProvider);
    final navKeys = ref.watch(tabNavKeysProvider);
    final urlSync = ref.watch(urlSyncProvider);
    final isWide = MediaQuery.sizeOf(context).width >= kRailBreakpoint;

    void onSelect(int i) => selectTab(ref, i);

    // The root navigator only holds the shell, so forward a system/browser back
    // to the active tab's navigator — otherwise nested pushes (trip detail, etc.)
    // couldn't be dismissed with the back button. At a tab root this is a no-op.
    final content = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        navKeys[ref.read(navIndexProvider)].currentState?.maybePop();
      },
      child: IndexedStack(
        index: index,
        children: [
          for (var i = 0; i < navKeys.length; i++)
            // TickerMode freezes hidden tabs' animations/tickers (an open
            // TripDetailScreen on a background tab otherwise keeps animating
            // offscreen) while keeping their state, scroll positions, and
            // GlobalKeys mounted — deliberately NOT unmounting or swapping
            // placeholders, and NOT keyed off ModalRoute.isCurrent (a hidden
            // tab's top route still reports current).
            TickerMode(
              enabled: i == index,
              child: _TabNavigator(
                navKey: navKeys[i],
                // Fresh observer instances every build: an observer may only
                // be attached to one navigator at a time (url_sync.dart).
                observers: [TabUrlObserver(urlSync, i)],
                child: _tabRoots[i],
              ),
            ),
        ],
      ),
    );

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: onSelect,
              labelType: NavigationRailLabelType.all,
              leading: const _RailBrand(),
              // Pin the account avatar to the bottom of the rail.
              trailingAtBottom: true,
              trailing: const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.lg),
                child: RailAccountButton(),
              ),
              destinations: [
                for (final (i, d) in navDestinations.indexed)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(_destinationLabel(l10n, i)),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onSelect,
        destinations: [
          for (final (i, d) in navDestinations.indexed)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: _destinationLabel(l10n, i),
            ),
        ],
      ),
    );
  }
}

const List<Widget> _tabRoots = [
  HomeScreen(),
  AgentScreen(),
  TripsListScreen(),
];

/// The Golden Tempo Travel brand mark for the top of the rail — the persistent
/// Site ID (Krug). The horseshoe mark on a light badge so it fits the narrow
/// rail and the black/gold artwork reads on the surface. Tapping it goes Home,
/// per the universal logo-links-home convention.
class _RailBrand extends ConsumerWidget {
  const _RailBrand();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
      child: BrandBadge(
        padding: const EdgeInsets.all(AppSpacing.sm),
        onTap: () => goHome(ref),
        child: const BrandLogo.mark(size: 36),
      ),
    );
  }
}

/// A tab's own [Navigator]: its root route is the tab screen; in-app pushes from
/// within the tab stack here so they animate inside the content area only.
class _TabNavigator extends StatelessWidget {
  final GlobalKey<NavigatorState> navKey;
  final List<NavigatorObserver> observers;
  final Widget child;

  const _TabNavigator(
      {required this.navKey, required this.observers, required this.child});

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navKey,
      observers: observers,
      onGenerateRoute: (settings) => MaterialPageRoute(
        builder: (_) => child,
        settings: settings,
      ),
    );
  }
}
