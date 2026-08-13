import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/chat_session.dart';
import '../navigation/app_nav.dart';
import '../providers/plan_provider.dart';
import '../providers/plan_resume.dart';
import '../providers/resumable_chats_provider.dart';
import '../theme/spacing.dart';
import 'offline_banner.dart' show relativeTime;
import 'section_header.dart';

/// In-progress AI conversations that haven't produced a trip yet
/// (specs/continue-where-you-left-off), as a self-contained home-screen
/// section. Collapses to nothing while loading, on error, when signed out,
/// or when there is nothing to resume.
///
/// [leading] hosts the recently-viewed-trip card on Home under the same
/// header — one "Continue where you left off" surface instead of two
/// adjacent sections saying the same thing.
class ContinueChatsSection extends ConsumerWidget {
  final Widget? leading;

  const ContinueChatsSection({super.key, this.leading});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A conversation that just produced a saved trip graduates out of the
    // continue section — refetch when the agent reports a saved trip.
    ref.listen(planProvider.select((s) => s.savedTripId), (prev, next) {
      if (next != null && next != prev) ref.invalidate(resumableChatsProvider);
    });

    final resumable = ref.watch(resumableChatsProvider).valueOrNull ??
        const <ChatSessionSummary>[];
    if (resumable.isEmpty && leading == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: context.l10n.continueChatsTitle),
        const SizedBox(height: AppSpacing.md),
        if (leading != null) ...[
          leading!,
          const SizedBox(height: AppSpacing.sm),
        ],
        for (final c in resumable) ContinueChatCard(chat: c),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

/// One in-progress AI conversation: tap to rehydrate it into the Plan tab,
/// dismiss (trailing ✕) to drop it from the section.
class ContinueChatCard extends ConsumerWidget {
  final ChatSessionSummary chat;

  const ContinueChatCard({super.key, required this.chat});

  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final ok = await resumePlanChat(
      chats: ref.read(chatsApiServiceProvider),
      plan: ref.read(planProvider.notifier),
      chatId: chat.chatId,
    );
    if (ok) {
      ref.read(navIndexProvider.notifier).state = AppTab.plan.index;
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.continueChatsReopenError)),
      );
    }
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await ref.read(chatsApiServiceProvider).dismissChat(chat.chatId);
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.continueChatsDismissError)),
      );
    }
    ref.invalidate(resumableChatsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final updated = DateTime.tryParse(chat.updatedAt);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.forum_outlined),
        title: Text(
          chat.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (chat.preview.isNotEmpty)
              Text(chat.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (updated != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  relativeTime(context.l10n, updated),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, size: 20),
          tooltip: context.l10n.continueChatsDismiss,
          onPressed: () => _dismiss(context, ref),
        ),
        onTap: () => _resume(context, ref),
      ),
    );
  }
}
