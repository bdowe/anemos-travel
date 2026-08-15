import 'package:flutter/widgets.dart';

/// Marks the subtree that renders inside the persistent navigation shell
/// (`AppShell`), which publishes it around the tab navigators.
///
/// The house app bar's brand is a logo-links-home affordance, and that only
/// means something where there is a home to go to. Nine screens render on the
/// root navigator, outside the shell — landing, auth, splash, SSO callback,
/// connect-app, verify, reset, shared trip, and the fullscreen trip map — and
/// on those a pointer cursor plus a "Home" tooltip that does nothing is a dead
/// affordance. Worst on `/share/<token>`, which strangers open.
///
/// Derived rather than declared: a `brandLinksHome: false` parameter would be
/// one more thing every future screen has to remember, and forgetting it fails
/// silently. Routes see inherited widgets sitting above their [Navigator], so
/// pages pushed on a tab navigator inherit this and root-navigator pushes
/// correctly do not.
///
/// Lives in its own file rather than beside `AppShell` so `gradient_app_bar`
/// can read it without importing the shell that imports every tab root.
class ShellScope extends InheritedWidget {
  const ShellScope({super.key, required super.child});

  /// Whether [context] is being built inside the shell.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellScope>() != null;

  @override
  bool updateShouldNotify(ShellScope oldWidget) => false;
}
