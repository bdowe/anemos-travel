import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/notification.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/notifications_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/money_format.dart';
import '../utils/snack.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/offline_banner.dart' show relativeTime;
import '../widgets/page_container.dart';
import 'admin_metrics_screen.dart';

/// The notification center (Wave 16): every notification as a durable,
/// read/unread feed row. Type-agnostic — each row renders from its `type` +
/// `payload`, so price drops, trip reminders and future types share one center.
/// Opening the center is the read action — mark-all-read fires on open, then
/// the badge clears.
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
    // Opening the center marks all notifications read (mark-all is the read
    // model), then refreshes both the feed (so rows show as read) and the badge.
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  Future<void> _markRead() async {
    try {
      await ref.read(notificationsApiServiceProvider).markRead();
    } catch (_) {
      // Best-effort: a failed mark-read shouldn't block reading the feed. The
      // badge simply stays until the next successful open.
    }
    if (!mounted) return;
    ref.invalidate(notificationsUnreadCountProvider);
    ref.invalidate(notificationsProvider);
  }

  // Clear-all: confirm, delete server-side, then refetch. The failure path
  // deliberately does NOT invalidate — the feed must keep showing the rows the
  // server still has, never a false empty state; the snackbar carries the why.
  Future<void> _clearAll() async {
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
    if (confirm != true || !mounted) return;
    try {
      await ref.read(notificationsApiServiceProvider).clearAll();
    } catch (e) {
      if (mounted) {
        showSnack(context, l10n.notifClearAllFailed(friendlyError(l10n, e)));
      }
      return;
    }
    if (!mounted) return;
    ref.invalidate(notificationsProvider);
    ref.invalidate(notificationsUnreadCountProvider);
  }

  @override
  Widget build(BuildContext context) {
    final notifs = ref.watch(notificationsProvider);
    final l10n = context.l10n;
    // The overflow menu renders only while the feed has loaded with rows —
    // there is nothing to clear during loading/error/empty, and a destructive
    // affordance over an unknown feed is noise. Watching the provider means it
    // disappears by itself right after a successful clear.
    //
    // Asked through maybeWhen, NOT valueOrNull: a refetch that fails (the
    // on-open mark-read invalidate, pull-to-refresh) yields an AsyncError that
    // still carries the previous rows, so valueOrNull would keep the menu alive
    // over the error panel below. Sharing `when`'s combinator is what keeps the
    // two in lockstep — the menu shows exactly when the body shows a list.
    final hasRows =
        notifs.maybeWhen(data: (list) => list.isNotEmpty, orElse: () => false);
    return Scaffold(
      appBar: GradientAppBar(
        title: Text(l10n.notifTitle),
        actions: [
          if (hasRows)
            // Destructive exits live behind an overflow menu, not a bare icon
            // (the trip-detail convention); the dialog is the second gate.
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: l10n.notifMoreActions,
              onSelected: (_) => _clearAll(),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'clear',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error),
                    title: Text(l10n.notifClearAll,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
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
            onRefresh: () async => ref.invalidate(notificationsProvider),
            // The list stays full-width (wheel/scrollbar/pull-to-refresh live
            // in the desktop gutters) while each row is capped by
            // PageContainer — the pattern page_container.dart documents.
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.lg),
              itemCount: list.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppSpacing.sm),
              itemBuilder: (_, i) => PageContainer(
                  child: _NotificationTile(notification: list[i])),
            ),
          );
        },
      ),
    );
  }
}

/// One feed row. The chrome (unread dot + timestamp + card) is shared; the body
/// is chosen by `type`: `price_drop` renders the flight-specific layout from its
/// payload, and any unrecognized type falls back to a generic title/subtitle so
/// a new backend type is never a blank row.
class _NotificationTile extends ConsumerWidget {
  final AppNotification notification;
  const _NotificationTile({required this.notification});

  /// Where this row leads, or null when it leads nowhere. Nullable by design:
  /// `InkWell(onTap: null)` renders no ripple, no hover cursor and no button
  /// semantics, so every type without a destination behaves exactly as it did
  /// before there was a tap target at all. This is the one place to add the
  /// next destination (`collab_edit` -> the trip, via `notification.tripId`).
  ///
  /// No admin gate on the ops arm: only admins are ever written `ops_alert`
  /// rows (the monitor fans out over `ListAdminUsers`), and the screen it
  /// opens is enforced by `adminMiddleware` server-side regardless. A second,
  /// client-side notion of who is an admin would be a duplicated derivation.
  VoidCallback? _tapAction(WidgetRef ref) => switch (notification.type) {
        'ops_alert' || 'ops_recovered' => () => pushOnActiveTab(
              ref,
              const AdminMetricsScreen(
                  initialTabIndex: AdminMetricsScreen.healthTabIndex),
              location: utilityLocation(BootUtility.adminMetrics),
            ),
        _ => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final unread = notification.isUnread;
    // tryParse: one malformed timestamp must degrade to a row without a
    // "when" line, never a FormatException that red-screens the whole center.
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

    return Card(
      // The ripple must be clipped to the card's rounded shape, or tapping
      // squares off the corners.
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _tapAction(ref),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Unread accent dot; a spacer keeps read rows aligned. The
              // Semantics label announces unread state to screen readers —
              // color/weight alone don't.
              Padding(
                padding: const EdgeInsets.only(top: 6, right: AppSpacing.md),
                child: Semantics(
                  label: unread ? context.l10n.notifUnreadSemantic : null,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: unread
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                    ),
                  ),
                ),
              ),
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
            ],
          ),
        ),
      ),
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
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
            color: unread
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          _dropLine(l10n),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
            color: unread
                ? Colors.green.shade800
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
/// drift apart.
///
/// Layout deliberately mirrors `_DegradedBanner` in `widgets/health_pane.dart`
/// (icon + title + reason bullets) WITHOUT its full-bleed errorContainer box —
/// the feed row already supplies card chrome, the unread dot and the
/// timestamp, so reusing the banner would nest a card inside a card. If a
/// third context ever needs this, extract the shared shape then.
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
    final reasons = _reasons;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: AppSpacing.sm),
          child: Icon(
            degraded ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            size: 18,
            color: degraded
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                degraded ? l10n.healthDegradedTitle : l10n.healthRecoveredTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                  color: unread
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              // Reason strings are canonical server values (computeHealthState
              // in ops_health.go) and operator-facing, exactly like the ops
              // alert email — rendered verbatim, only the headline is
              // localized.
              for (final r in reasons) ...[
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
          ),
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
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
            color: unread
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
          ),
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
/// All read as "<who> <did what> <trip>" with a leading icon, built from the
/// payload's actor/trip fields.
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
    final IconData icon;
    final String headline;
    if (type == 'invite_accepted') {
      final who = payload['accepter_name'] is String
          ? payload['accepter_name'] as String
          : l10n.notifSomeone;
      icon = Icons.group_add_outlined;
      headline = l10n.notifJoinedTrip(who, tripTitle);
    } else if (type == 'share_joined') {
      final who = payload['joiner_name'] is String
          ? payload['joiner_name'] as String
          : l10n.notifSomeone;
      icon = Icons.group_add_outlined;
      headline = payload['role'] == 'viewer'
          ? l10n.notifFollowedTrip(who, tripTitle)
          : l10n.notifJoinedTrip(who, tripTitle);
    } else {
      final who = payload['actor_name'] is String
          ? payload['actor_name'] as String
          : l10n.notifACollaborator;
      icon = Icons.edit_outlined;
      headline = l10n.notifEditedTrip(who, tripTitle);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: AppSpacing.sm),
          child: Icon(
            icon,
            size: 18,
            color: unread
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Text(
            headline,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
              color: unread
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
