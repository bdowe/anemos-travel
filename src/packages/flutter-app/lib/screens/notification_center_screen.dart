import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/notification.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/notifications_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/money_format.dart';
import '../utils/snack.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/offline_banner.dart' show relativeTime;
import '../widgets/page_container.dart';
import 'account_settings_screen.dart';
import 'admin_metrics_screen.dart';

/// The notification center, in two presentations sharing one feed (the Midday
/// popover pattern): [NotificationsPanel] is the desktop popover the rail bell
/// opens (account_menu.dart), and [NotificationCenterScreen] stays the full
/// page for narrow widths and URL deep links. Rows are flat and
/// hairline-divided — a leading type-icon chip, weight-not-size unread
/// emphasis, a trailing unread dot — grouped into New/Earlier while unread
/// rows exist. Clear-all lives as a quiet footer action (the confirm dialog
/// remains the gate); the server has no per-item or archive endpoints, so
/// those are the whole inbox vocabulary.
///
/// Type-agnostic as before: each row renders from `type` + `payload`, so trip
/// signals, ops alerts and future types share one feed.

/// Fixed popover width — wide enough for two-line rows, narrow enough to read
/// as a satellite of the rail (the account popup caps at 280).
const double _panelWidth = 380;

/// Height cap for the popover's scrolling feed region (header and footer sit
/// outside it).
const double _panelBodyMaxHeight = 400;

/// Fixed height of the popover's loading/empty/error states, so the panel
/// doesn't jump between them while the feed settles.
const double _panelStateHeight = 300;

/// Opening the center — page or popover — is the read action, in this order:
/// refetch the feed, and only once rows have actually loaded mark them read
/// server-side, then refresh the badge. Sequenced, not parallel, for two
/// reasons: marking read before the fetch resolves would return an already
/// read list (the unread dots would be gone before they were ever seen), and
/// marking read when the fetch FAILED would clear the badge for rows the user
/// never saw. The feed provider is deliberately NOT re-invalidated after the
/// mark-read: the session keeps the unread flags it fetched, so the "New"
/// section holds still while it's being read; the next open refetches.
Future<void> markNotificationsSeen(
  WidgetRef ref, {
  required bool Function() alive,
}) async {
  ref.invalidate(notificationsProvider);
  try {
    await ref.read(notificationsProvider.future);
  } catch (_) {
    return; // Failed load: nothing was seen, the badge stays.
  }
  if (!alive()) return;
  try {
    await ref.read(notificationsApiServiceProvider).markRead();
  } catch (_) {
    return; // Best-effort: the badge clears on the next successful open.
  }
  if (!alive()) return;
  ref.invalidate(notificationsUnreadCountProvider);
}

/// Clear-all: confirm, delete server-side, then refetch. The failure path
/// deliberately does NOT invalidate — the feed must keep showing the rows the
/// server still has, never a false empty state; the snackbar carries the why.
Future<void> _confirmAndClearAll(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final confirm = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.notifClearAllTitle),
      content: Text(l10n.notifClearAllBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.commonDelete),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return;
  try {
    await ref.read(notificationsApiServiceProvider).clearAll();
  } catch (e) {
    if (context.mounted) {
      showSnack(context, l10n.notifClearAllFailed(friendlyError(l10n, e)));
    }
    return;
  }
  if (!context.mounted) return;
  ref.invalidate(notificationsProvider);
  ref.invalidate(notificationsUnreadCountProvider);
}

/// Settings affordance shared by the page's app bar and the popover header.
/// Links to the existing account-settings route — the panel never grows its
/// own settings UI.
void _openAccountSettings(WidgetRef ref) {
  pushOnActiveTab(ref, const AccountSettingsScreen(),
      location: utilityLocation(BootUtility.account));
}

/// The full-page presentation: the deep-link destination
/// (BootUtility.notifications) and the whole experience below the rail
/// breakpoint, where the popover has no anchor.
class NotificationCenterScreen extends ConsumerStatefulWidget {
  const NotificationCenterScreen({super.key});

  @override
  ConsumerState<NotificationCenterScreen> createState() =>
      _NotificationCenterScreenState();
}

class _NotificationCenterScreenState
    extends ConsumerState<NotificationCenterScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => markNotificationsSeen(ref, alive: () => mounted));
  }

  void _openSettings() {
    // This screen sits on the active tab's top route, so pushOnActiveTab
    // targets the very navigator isTopRoute reports on — a rapid double tap
    // would otherwise stack two settings screens.
    if (!isTopRoute(context)) return;
    _openAccountSettings(ref);
  }

  @override
  Widget build(BuildContext context) {
    final notifs = ref.watch(notificationsProvider);
    final l10n = context.l10n;
    return Scaffold(
      appBar: GradientAppBar(
        title: l10n.notifTitle,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.accountMenuAccountSettings,
            onPressed: _openSettings,
          ),
        ],
      ),
      body: notifs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => PageContainer(
          child: EmptyState(
            icon: Icons.cloud_off,
            title: l10n.notifLoadErrorTitle,
            message: friendlyError(l10n, e),
            actions: [
              FilledButton(
                onPressed: () => ref.invalidate(notificationsProvider),
                child: Text(l10n.commonRetry),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return PageContainer(
              child: EmptyState(
                icon: Icons.notifications_none,
                title: l10n.notifEmptyTitle,
                message: l10n.notifEmptyMessage,
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(notificationsProvider);
              try {
                await ref.read(notificationsProvider.future);
              } catch (_) {
                // The error panel below reports it; the indicator just stops.
              }
            },
            // The scroll view stays full-width (wheel/scrollbar/
            // pull-to-refresh live in the desktop gutters) while the feed
            // plate is capped by PageContainer — the pattern
            // page_container.dart documents. One card holds the whole feed;
            // rows separate with hairlines, not per-row card chrome.
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                PageContainer(
                  child: Card(
                    margin: EdgeInsets.zero,
                    // The ripple must be clipped to the card's rounded shape,
                    // or tapping squares off the corners.
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ..._feedChildren(context, list),
                        const _ClearAllFooter(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The popover presentation, opened by the rail bell (account_menu.dart) on
/// wide layouts. Same feed, panel chrome: serif header + settings gear,
/// capped scrolling body, quiet Clear-all footer. [onClose] closes the menu
/// before any navigation the panel triggers.
class NotificationsPanel extends ConsumerWidget {
  final VoidCallback onClose;
  const NotificationsPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final notifs = ref.watch(notificationsProvider);
    final hasRows =
        notifs.maybeWhen(data: (list) => list.isNotEmpty, orElse: () => false);
    // The menu surface (menuTheme) carries the 12px card shape; clip the
    // panel's square innards — full-bleed hairlines, the footer strip — to it.
    return ClipRRect(
      borderRadius: AppRadius.mdAll,
      child: SizedBox(
        width: _panelWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Text(l10n.notifTitle,
                        style: theme.textTheme.headlineSmall),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    tooltip: l10n.accountMenuAccountSettings,
                    onPressed: () {
                      onClose();
                      _openAccountSettings(ref);
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            notifs.when(
              loading: () => const SizedBox(
                height: _panelStateHeight,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SizedBox(
                height: _panelStateHeight,
                child: Center(child: _CompactErrorState(error: e)),
              ),
              data: (list) => list.isEmpty
                  ? const SizedBox(
                      height: _panelStateHeight,
                      child: Center(child: _CompactEmptyState()),
                    )
                  : ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxHeight: _panelBodyMaxHeight),
                      child: SingleChildScrollView(
                        // Not the primary controller: the menu overlay owns
                        // its own scrollable, and two positions on one
                        // controller breaks its scrollbar.
                        primary: false,
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _feedChildren(context, list,
                              onBeforeNavigate: onClose),
                        ),
                      ),
                    ),
            ),
            if (hasRows) const _ClearAllFooter(),
          ],
        ),
      ),
    );
  }
}

/// The feed body both presentations render: rows split into New (unread) and
/// Earlier (read) while unread rows exist — the honest stand-in for Midday's
/// Inbox/Archive tabs given a mark-all-read API — and a flat hairline list
/// otherwise. The feed arrives newest-first and mark-read is all-or-nothing,
/// so unread rows are always a prefix; the split never reorders anything.
List<Widget> _feedChildren(
  BuildContext context,
  List<AppNotification> list, {
  VoidCallback? onBeforeNavigate,
}) {
  final l10n = context.l10n;
  List<Widget> rows(List<AppNotification> section) => [
        for (var i = 0; i < section.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _NotificationRow(
            notification: section[i],
            onBeforeNavigate: onBeforeNavigate,
          ),
        ],
      ];

  final fresh = [
    for (final n in list)
      if (n.isUnread) n
  ];
  if (fresh.isEmpty) return rows(list);

  final earlier = [
    for (final n in list)
      if (!n.isUnread) n
  ];
  return [
    _SectionHeader(l10n.notifSectionNew),
    ...rows(fresh),
    if (earlier.isNotEmpty) ...[
      const Divider(height: 1),
      _SectionHeader(l10n.notifSectionEarlier),
      ...rows(earlier),
    ],
  ];
}

/// Sentence-case Inter section label — row-header register (weight, not size,
/// and never the letterspaced-caps eyebrow, which belongs to destinations).
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xs),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The type-icon chip leading every row: a quiet neutral circle so color
/// stays single-meaning — only ops_alert's warning earns a colored icon.
(IconData, Color?) _leadingIconFor(String type, ColorScheme scheme) =>
    switch (type) {
      'price_drop' => (Icons.trending_down, null),
      'collab_edit' => (Icons.edit_outlined, null),
      'invite_accepted' || 'share_joined' => (Icons.group_add_outlined, null),
      'ops_alert' => (Icons.warning_amber_rounded, scheme.error),
      'ops_recovered' => (Icons.check_circle_outline, null),
      _ => (Icons.notifications_none, null),
    };

/// One feed row, Midday anatomy in this app's materials: icon chip, text
/// block with the relative time beneath, trailing unread dot. The body is
/// chosen by `type`; any unrecognized type falls back to a generic
/// title/subtitle so a new backend type is never a blank row.
class _NotificationRow extends ConsumerWidget {
  final AppNotification notification;

  /// Popover hook: closes the panel before a row navigates. Null on the page.
  final VoidCallback? onBeforeNavigate;

  const _NotificationRow({required this.notification, this.onBeforeNavigate});

  /// Where this row leads, or null when it leads nowhere. Nullable by design:
  /// `InkWell(onTap: null)` renders no ripple, no hover cursor and no button
  /// semantics, so every type without a destination behaves exactly as it did
  /// before there was a tap target at all. This is the one place to add the
  /// next destination (`collab_edit` -> the trip, via `notification.tripId`).
  ///
  /// No admin gate on the ops arm: only admins are ever written `ops_alert`
  /// rows (the monitor fans out over `ListAdminUsers`), and the screen it
  /// opens is enforced by `adminMiddleware` server-side regardless.
  VoidCallback? _tapAction(BuildContext context, WidgetRef ref) =>
      switch (notification.type) {
        'ops_alert' || 'ops_recovered' => () {
            // On the page this row sits on the active tab's top route, so
            // pushOnActiveTab targets the very navigator isTopRoute reports
            // on — a rapid double tap would otherwise stack two admin
            // screens. In the popover the menu route is current, and closing
            // it first hands the push the same guarantee.
            if (!isTopRoute(context)) return;
            onBeforeNavigate?.call();
            pushOnActiveTab(
              ref,
              const AdminMetricsScreen(
                  initialTabIndex: AdminMetricsScreen.healthTabIndex),
              location: utilityLocation(BootUtility.adminMetrics),
            );
          },
        _ => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final unread = notification.isUnread;
    // tryParse: one malformed timestamp must degrade to a row without a
    // "when" line, never a FormatException that red-screens the whole feed.
    final createdAt = DateTime.tryParse(notification.createdAt);
    final when = createdAt == null
        ? null
        : relativeTime(context.l10n, createdAt.toLocal());

    final content = switch (notification.type) {
      'price_drop' =>
        _PriceDropBody(payload: notification.payload, unread: unread),
      'collab_edit' || 'invite_accepted' || 'share_joined' => _TripSignalBody(
          type: notification.type,
          payload: notification.payload,
          unread: unread,
        ),
      'ops_alert' || 'ops_recovered' => _OpsBody(
          type: notification.type,
          payload: notification.payload,
          unread: unread,
        ),
      _ => _GenericBody(
          type: notification.type,
          payload: notification.payload,
          unread: unread,
        ),
    };

    final (icon, iconColor) =
        _leadingIconFor(notification.type, theme.colorScheme);

    return InkWell(
      onTap: _tapAction(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              child: Icon(icon,
                  size: 18,
                  color: iconColor ?? theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  content,
                  if (when != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      when,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (unread)
              // Trailing accent dot, aligned to the first text line. The
              // Semantics label announces unread state to screen readers —
              // color/weight alone don't.
              Padding(
                padding:
                    const EdgeInsets.only(left: AppSpacing.md, top: 6),
                child: Semantics(
                  label: context.l10n.notifUnreadSemantic,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Unread carries weight and full ink; read rows step back to the variant
/// tone — hierarchy on the Inter weight ladder, sizes untouched.
TextStyle? _rowTitleStyle(ThemeData theme, bool unread) =>
    theme.textTheme.bodyMedium?.copyWith(
      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
      color: unread
          ? theme.colorScheme.onSurface
          : theme.colorScheme.onSurfaceVariant,
    );

/// Compact caught-up state for the popover (the page keeps the shared
/// EmptyState at page scale — same copy, one voice).
class _CompactEmptyState extends StatelessWidget {
  const _CompactEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.surfaceContainerHighest,
          ),
          child: Icon(Icons.notifications_none,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.notifEmptyTitle,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: Text(
            l10n.notifEmptyMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// Compact load-failure state for the popover, with the same retry the page
/// offers.
class _CompactErrorState extends ConsumerWidget {
  final Object error;
  const _CompactErrorState({required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off,
            size: 24, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.notifLoadErrorTitle,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: Text(
            friendlyError(l10n, error),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: () => ref.invalidate(notificationsProvider),
          child: Text(l10n.commonRetry),
        ),
      ],
    );
  }
}

/// The quiet destructive exit, Midday's footer move: a full-width hairlined
/// strip below the feed. Neutral ink on purpose — the confirm dialog carries
/// the destructive framing. Rendered only while rows exist (there is nothing
/// to clear over loading/error/empty, and a destructive affordance over an
/// unknown feed is noise); both presentations gate it on the same
/// data-with-rows branch that renders the feed, so it disappears by itself
/// right after a successful clear.
class _ClearAllFooter extends ConsumerWidget {
  const _ClearAllFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurfaceVariant,
            minimumSize: const Size(0, kMinTouchTarget),
            shape: const RoundedRectangleBorder(),
          ),
          onPressed: () => _confirmAndClearAll(context, ref),
          child: Text(context.l10n.notifClearAll),
        ),
      ],
    );
  }
}

/// The price-drop layout: route, the drop ("$412, down from $498") and the
/// (possibly flexible) dates — built entirely from the payload map.
class _PriceDropBody extends StatelessWidget {
  final Map<String, dynamic> payload;
  final bool unread;
  const _PriceDropBody({required this.payload, required this.unread});

  String? _str(String k) {
    final v = payload[k];
    return v is String ? v : null;
  }

  double? _num(String k) {
    final v = payload[k];
    return v is num ? v.toDouble() : null;
  }

  String _dropLine(AppLocalizations l10n) {
    final price = _num('price') ?? 0;
    final currency = _str('currency') ?? '';
    final now = formatMoney(price, currency);
    final prev = _num('previous_price');
    if (prev != null) {
      return l10n.notifDownFrom(now, formatMoney(prev, currency));
    }
    return now;
  }

  String _datesLine(AppLocalizations l10n) {
    final depart = _str('depart_date') ?? '';
    final matched = _str('matched_date');
    var s = matched ?? depart;
    final ret = _str('return_date');
    if (ret != null) s += ' → $ret';
    if (matched != null && matched != depart) {
      s += ' ${l10n.notifBestInWindow}';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final origin = _str('origin') ?? '';
    final destination = _str('destination') ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$origin → $destination',
          style: _rowTitleStyle(theme, unread),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          _dropLine(l10n),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
            color: unread
                ? AppColors.onSuccessContainer
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _datesLine(l10n),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Ops health signals for admins (`ops_alert` / `ops_recovered`, written by
/// the API's health self-check). The payload carries `{degraded, reasons[]}`,
/// so the row names WHAT is wrong — "backups stale", "AI provider failing:
/// credit balance" — instead of falling through to [_GenericBody], which could
/// only title-case the type into a contentless "Ops Alert".
///
/// The variant comes from `type`, not `payload['degraded']`: the type is
/// already the discriminator, and deriving the same fact twice is how the two
/// drift apart. The alert/recovered icon lives in the row's leading chip.
class _OpsBody extends StatelessWidget {
  final String type;
  final Map<String, dynamic> payload;
  final bool unread;
  const _OpsBody({
    required this.type,
    required this.payload,
    required this.unread,
  });

  /// The reasons the server recorded, defensively parsed: a malformed or
  /// absent list must degrade to "no bullets", never throw in a feed row.
  List<String> get _reasons {
    final raw = payload['reasons'];
    return raw is List ? raw.whereType<String>().toList() : const [];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final degraded = type == 'ops_alert';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          degraded ? l10n.healthDegradedTitle : l10n.healthRecoveredTitle,
          style: _rowTitleStyle(theme, unread),
        ),
        // Reason strings are canonical server values (computeHealthState in
        // ops_health.go) and operator-facing, exactly like the ops alert
        // email — rendered verbatim, only the headline is localized.
        for (final r in _reasons) ...[
          const SizedBox(height: 2),
          Text(
            '• $r',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 2),
        // Without a hint the row is silently tappable — the exact
        // discoverability gap this screen already had.
        Text(
          l10n.notifOpsOpenHealth,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      ],
    );
  }
}

/// Fallback layout for any type the client doesn't specialize yet. Reads a
/// `title` (or `message`/`body`) from the payload, else humanizes the type
/// name, so a newly-added backend notification always renders something
/// sensible instead of a blank row.
///
/// A row showing a title-cased type name (e.g. "Ops Alert") is the signal that
/// the type has outgrown this fallback and wants its own arm in the switch
/// above.
class _GenericBody extends StatelessWidget {
  final String type;
  final Map<String, dynamic> payload;
  final bool unread;
  const _GenericBody({
    required this.type,
    required this.payload,
    required this.unread,
  });

  static String _humanize(String type, AppLocalizations l10n) {
    if (type.isEmpty) return l10n.notifGenericFallback;
    return type
        .split(RegExp(r'[_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title =
        (payload['title'] is String && (payload['title'] as String).isNotEmpty)
            ? payload['title'] as String
            : _humanize(type, context.l10n);
    final subtitle = payload['message'] is String
        ? payload['message'] as String
        : payload['body'] is String
            ? payload['body'] as String
            : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: _rowTitleStyle(theme, unread),
          overflow: TextOverflow.ellipsis,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Trip collaboration signals: a co-planner edited a shared trip
/// (`collab_edit`), someone accepted an invite (`invite_accepted`), or someone
/// redeemed a share link (`share_joined` — viewer joins read as "following").
/// All read as "<who> <did what> <trip>", with the type's icon in the row's
/// leading chip.
class _TripSignalBody extends StatelessWidget {
  final String type;
  final Map<String, dynamic> payload;
  final bool unread;
  const _TripSignalBody({
    required this.type,
    required this.payload,
    required this.unread,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final tripTitle = payload['trip_title'] is String
        ? payload['trip_title'] as String
        : l10n.notifSomeTrip;
    final String headline;
    if (type == 'invite_accepted') {
      final who = payload['accepter_name'] is String
          ? payload['accepter_name'] as String
          : l10n.notifSomeone;
      headline = l10n.notifJoinedTrip(who, tripTitle);
    } else if (type == 'share_joined') {
      final who = payload['joiner_name'] is String
          ? payload['joiner_name'] as String
          : l10n.notifSomeone;
      headline = payload['role'] == 'viewer'
          ? l10n.notifFollowedTrip(who, tripTitle)
          : l10n.notifJoinedTrip(who, tripTitle);
    } else {
      final who = payload['actor_name'] is String
          ? payload['actor_name'] as String
          : l10n.notifACollaborator;
      headline = l10n.notifEditedTrip(who, tripTitle);
    }
    return Text(headline, style: _rowTitleStyle(theme, unread));
  }
}
