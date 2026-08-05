import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/notifications_provider.dart';
import '../providers/auth_provider.dart';
import '../screens/account_settings_screen.dart';
import '../screens/admin_metrics_screen.dart';
import '../screens/alerts_screen.dart';
import '../screens/onboarding_quiz_screen.dart';
import '../screens/preferences_screen.dart';
import '../screens/local_admin_screen.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';

/// Single uppercase letter for the account avatar.
String _initialFor(String displayName) {
  final t = displayName.trim();
  return t.isEmpty ? '?' : t[0].toUpperCase();
}

/// One style for the avatar initial everywhere it renders, so the popup
/// header, app-bar avatar and rail avatar can't drift apart.
TextStyle? _avatarLabelStyle(ThemeData theme) => theme.textTheme.labelLarge
    ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600);

/// Icon + label row for the popup actions. `Flexible` + ellipsis keeps long
/// translations inside the 280px popup cap instead of overflowing the row.
Widget _menuRow(Widget icon, String label) => Row(
      children: [
        icon,
        const SizedBox(width: AppSpacing.md),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

void _onSelected(BuildContext context, WidgetRef ref, String value) {
  if (value == 'logout') {
    ref.read(authProvider.notifier).logout();
  } else if (value == 'preferences') {
    // Push onto the active tab's navigator so the rail/bar stays put.
    pushOnActiveTab(ref, const PreferencesScreen(),
        location: utilityLocation(BootUtility.preferences));
  } else if (value == 'alerts') {
    pushOnActiveTab(ref, const AlertsScreen(),
        location: utilityLocation(BootUtility.alerts));
  } else if (value == 'retake_quiz') {
    // No location: a transient flow, not a page worth restoring on refresh.
    pushOnActiveTab(ref, const OnboardingQuizScreen(retake: true));
  } else if (value == 'account_settings') {
    pushOnActiveTab(ref, const AccountSettingsScreen(),
        location: utilityLocation(BootUtility.account));
  } else if (value == 'local_admin') {
    pushOnActiveTab(ref, const LocalAdminScreen(),
        location: utilityLocation(BootUtility.adminLocal));
  } else if (value == 'admin_metrics') {
    pushOnActiveTab(ref, const AdminMetricsScreen(),
        location: utilityLocation(BootUtility.adminMetrics));
  }
}

/// The shared menu: an identity header (name + email) plus Travel profile and
/// Sign out. Used by both presentations below.
List<PopupMenuEntry<String>> _items(
  ThemeData theme,
  AppLocalizations l10n,
  String? displayName,
  String? email, {
  bool isAdmin = false,
  int unreadAlerts = 0,
}) {
  return [
    if (displayName != null) ...[
      // Identity, not an action — styled explicitly so the disabled item
      // doesn't read as greyed-out.
      PopupMenuItem<String>(
        enabled: false,
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.brand,
              child: Text(
                _initialFor(displayName),
                style: _avatarLabelStyle(theme),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (email != null)
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
      const PopupMenuDivider(),
    ],
    PopupMenuItem<String>(
      value: 'preferences',
      child: _menuRow(
        Icon(Icons.tune, size: 20, color: theme.colorScheme.onSurfaceVariant),
        l10n.accountMenuTravelProfile,
      ),
    ),
    PopupMenuItem<String>(
      value: 'alerts',
      child: _menuRow(
        unreadAlerts > 0
            ? Badge.count(
                count: unreadAlerts,
                child: Icon(Icons.notifications_none,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
              )
            : Icon(Icons.notifications_none,
                size: 20, color: theme.colorScheme.onSurfaceVariant),
        l10n.accountMenuPriceAlerts,
      ),
    ),
    PopupMenuItem<String>(
      value: 'retake_quiz',
      child: _menuRow(
        Icon(Icons.refresh,
            size: 20, color: theme.colorScheme.onSurfaceVariant),
        l10n.accountMenuRetakeQuiz,
      ),
    ),
    PopupMenuItem<String>(
      value: 'account_settings',
      child: _menuRow(
        Icon(Icons.manage_accounts_outlined,
            size: 20, color: theme.colorScheme.onSurfaceVariant),
        l10n.accountMenuAccountSettings,
      ),
    ),
    if (isAdmin) ...[
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: 'local_admin',
        child: _menuRow(
          Icon(Icons.verified, size: 20, color: AppColors.toolLocal),
          l10n.accountMenuLocalIntelAdmin,
        ),
      ),
      PopupMenuItem<String>(
        value: 'admin_metrics',
        child: _menuRow(
          Icon(Icons.insights,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
          l10n.accountMenuMetrics,
        ),
      ),
    ],
    const PopupMenuDivider(),
    PopupMenuItem<String>(
      value: 'logout',
      child: _menuRow(
        Icon(Icons.logout, size: 20, color: theme.colorScheme.onSurfaceVariant),
        l10n.accountMenuSignOut,
      ),
    ),
  ];
}

/// Account action for a tab's app bar (narrow layouts). On wide layouts the
/// rail's [RailAccountButton] carries account access, so this renders nothing to
/// avoid duplicating it.
class AccountMenu extends ConsumerWidget {
  const AccountMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MediaQuery.sizeOf(context).width >= kRailBreakpoint) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final user = ref.watch(authProvider).user;
    final unread = ref.watch(notificationsUnreadCountProvider).valueOrNull ?? 0;
    final avatar = user != null
        ? CircleAvatar(
            radius: 16,
            backgroundColor: Colors.white.withValues(alpha: 0.25),
            child: Text(
              _initialFor(user.displayName),
              style: _avatarLabelStyle(theme),
            ),
          )
        : const Icon(Icons.account_circle);
    return PopupMenuButton<String>(
      tooltip: l10n.accountMenuTooltip,
      // Open below the bar, on an M3 surface, instead of the default overlapping
      // panel that would inherit the app bar's white icons.
      position: PopupMenuPosition.under,
      color: theme.colorScheme.surface,
      elevation: 3,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      icon: unread > 0 ? Badge.count(count: unread, child: avatar) : avatar,
      onSelected: (v) => _onSelected(context, ref, v),
      itemBuilder: (_) => _items(theme, l10n, user?.displayName, user?.email,
          isAdmin: user?.isAdmin ?? false, unreadAlerts: unread),
    );
  }
}

/// Account avatar for the nav rail's trailing slot (wide layouts). The rail is a
/// light surface, so the avatar is teal-filled rather than white-on-teal.
class RailAccountButton extends ConsumerWidget {
  const RailAccountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final user = ref.watch(authProvider).user;
    final unread = ref.watch(notificationsUnreadCountProvider).valueOrNull ?? 0;
    final avatar = CircleAvatar(
      radius: 18,
      backgroundColor: AppColors.brand,
      child: Text(
        user != null ? _initialFor(user.displayName) : '?',
        style: _avatarLabelStyle(theme),
      ),
    );
    return PopupMenuButton<String>(
      tooltip: l10n.accountMenuTooltip,
      color: theme.colorScheme.surface,
      elevation: 3,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      icon: unread > 0 ? Badge.count(count: unread, child: avatar) : avatar,
      onSelected: (v) => _onSelected(context, ref, v),
      itemBuilder: (_) => _items(theme, l10n, user?.displayName, user?.email,
          isAdmin: user?.isAdmin ?? false, unreadAlerts: unread),
    );
  }
}
