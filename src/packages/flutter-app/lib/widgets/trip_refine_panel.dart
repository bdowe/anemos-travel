import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/plan_provider.dart';
import '../utils/errors.dart';
import 'chat_panel.dart';

/// Which slice of the itinerary an AI refinement session targets. Mirrors the
/// server tool's section selector: one day (optionally qualified by city,
/// since day numbers repeat across cities in legacy trips), one city/hub, or
/// the whole trip.
class RefineTarget {
  final String scope; // 'trip' | 'day' | 'city'
  final int? day;
  final String? city;

  /// General-purpose "Trip assistant" flavor: same whole-trip scope, but the
  /// framing invites questions rather than assuming every message is an edit.
  final bool assistant;

  const RefineTarget._(this.scope, this.day, this.city,
      {this.assistant = false});
  const RefineTarget.trip() : this._('trip', null, null);
  const RefineTarget.assistant() : this._('trip', null, null, assistant: true);
  const RefineTarget.day(int day, {String? city}) : this._('day', day, city);
  const RefineTarget.city(String city) : this._('city', null, city);

  /// Canonical **English** section name. This is embedded verbatim in the
  /// refine seed prompt sent to the agent (`trip_detail_screen.dart`), so it is
  /// never localized — see [displayLabel] for the user-facing equivalent
  /// (specs/i18n-spanish).
  String get label {
    switch (scope) {
      case 'day':
        return city == null ? 'Day $day' : 'Day $day — $city';
      case 'city':
        return city!;
      default:
        return 'Whole trip';
    }
  }

  /// Localized twin of [label], for anything the user reads.
  String displayLabel(AppLocalizations l10n) {
    switch (scope) {
      case 'day':
        return city == null
            ? l10n.refineTargetDay(day!)
            : l10n.refineTargetDayCity(day!, city!);
      case 'city':
        return city!;
      default:
        return l10n.refineTargetWholeTrip;
    }
  }
}

/// Where the trip's saved conversation is in its restore
/// (specs/trip-refine-memory). Owned by the host screen; the panel only draws
/// it, so the two can never disagree about whether a composer should exist.
enum RefineChatPhase {
  /// Nothing to restore, or the restore finished — the chat is live.
  ready,

  /// Fetching the stored transcript. The composer is deliberately ABSENT, not
  /// disabled: a message typed at 200 ms must not be sendable with no history
  /// behind it, because the transcript is upserted wholesale and would
  /// overwrite the stored conversation with one message.
  restoring,

  /// The conversation is gone (pruned with its trip, or already cleared).
  /// Terminal — a retry would fail identically, so we only offer a new chat.
  expired,

  /// The restore failed for a reason that might not repeat.
  failed,
}

/// The in-page AI refinement chat for one trip, shown beside (wide layouts) or
/// over (bottom sheet) the trip detail page. Drives the per-trip
/// [tripRefineProvider] session.
///
/// The host screen owns the trip-update listener: this panel can be closed
/// mid-turn (back closes it since specs/trip-refine-memory), and a patch that
/// lands afterwards must still refresh the itinerary.
class TripRefinePanel extends ConsumerWidget {
  final String tripId;
  final RefineChatPhase phase;

  /// The failure behind [RefineChatPhase.failed], rendered via [friendlyError].
  final Object? error;
  final VoidCallback onClose;
  final VoidCallback onNewChat;
  final VoidCallback? onRetry;

  const TripRefinePanel({
    super.key,
    required this.tripId,
    required this.onClose,
    required this.onNewChat,
    this.phase = RefineChatPhase.ready,
    this.error,
    this.onRetry,
  });

  /// The newest context chip in the conversation — what the traveler last
  /// pointed the chat at.
  String? _newestChapter(WidgetRef ref) {
    final messages = ref.watch(
        tripRefineProvider(tripId).select((s) => s.messages));
    for (final m in messages.reversed) {
      final label = m.displayLabel;
      if (label != null && label.isNotEmpty) return label;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // The header is a function of the transcript, never of screen state a
    // gesture can destroy: a ✨ tap appends its own labeled seed, so the newest
    // chapter is already correct by the time this builds.
    final chapter = _newestChapter(ref);
    final title = chapter ?? l10n.refineAssistantTitle;
    final hasConversation = ref.watch(
        tripRefineProvider(tripId).select((s) => s.messages.isNotEmpty));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Icon(
                chapter == null
                    ? Icons.chat_bubble_outline
                    : Icons.auto_awesome,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // The only thing that discards a trip's conversation, now that no
              // ✨ tap does.
              if (phase == RefineChatPhase.ready && hasConversation)
                IconButton(
                  icon: const Icon(Icons.add_comment_outlined),
                  tooltip: l10n.refineNewChat,
                  onPressed: onNewChat,
                ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: l10n.commonClose,
                onPressed: onClose,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body(context, l10n)),
      ],
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    switch (phase) {
      case RefineChatPhase.restoring:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                  width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(height: 12),
              Text(l10n.refineResumeLoading,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
      case RefineChatPhase.expired:
        return _Problem(
          icon: Icons.history_toggle_off,
          title: l10n.refineResumeGone,
          detail: l10n.refineResumeGoneDetail,
          // No retry: the transcript is gone, so retrying fails identically.
          actions: [
            FilledButton(onPressed: onNewChat, child: Text(l10n.refineNewChat)),
          ],
        );
      case RefineChatPhase.failed:
        return _Problem(
          icon: Icons.error_outline,
          title: l10n.refineResumeFailed,
          detail: friendlyError(l10n, error),
          actions: [
            if (onRetry != null)
              FilledButton(onPressed: onRetry, child: Text(l10n.commonRetry)),
            TextButton(onPressed: onNewChat, child: Text(l10n.refineNewChat)),
          ],
        );
      case RefineChatPhase.ready:
        return ChatPanel(
          state: tripRefineProvider(tripId),
          notifier: tripRefineProvider(tripId).notifier,
          // One running conversation carries both jobs — questions and edits —
          // so the open-ended hint is the honest one.
          inputHint: l10n.refineAssistantHint,
        );
    }
  }
}

class _Problem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final List<Widget> actions;

  const _Problem({
    required this.icon,
    required this.title,
    required this.detail,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scrollable: on narrow the panel is a drag sheet that opens at 0.45 of
    // the screen, which is shorter than this block — and an unreachable
    // "New chat" button is the same dead end the state exists to escape.
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Wrap(spacing: 8, children: actions),
          ],
        ),
      ),
    );
  }
}
