import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/chat_session.dart';
import '../models/plan_message.dart';
import '../navigation/app_nav.dart';
import '../providers/plan_provider.dart';
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
        const SizedBox(height: AppSpacing.sm),
        if (leading != null) ...[
          leading!,
          const SizedBox(height: AppSpacing.sm),
        ],
        for (final c in resumable) ContinueChatCard(chat: c),
        const SizedBox(height: AppSpacing.lg),
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
    try {
      final detail =
          await ref.read(chatsApiServiceProvider).getChat(chat.chatId);
      ref.read(planProvider.notifier).resumeConversation(
            chatId: detail.chatId,
            summary: detail.summary,
            messages: [
              for (final m in detail.messages)
                PlanMessage(
                  role: m.role == 'user'
                      ? MessageRole.user
                      : MessageRole.assistant,
                  content: m.content,
                  // Restores the seed context chip (e.g. "Near my current
                  // location") instead of the raw coordinate bubble.
                  displayLabel: m.displayLabel,
                  // Pixels are stripped server-side; null bytes renders the
                  // "Image" placeholder chip and stays out of resent history.
                  attachments: [
                    for (final img in m.images)
                      PlanAttachment(bytes: null, mediaType: img.mediaType),
                  ],
                ),
            ],
          );
      ref.read(navIndexProvider.notifier).state = AppTab.plan.index;
    } catch (_) {
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
