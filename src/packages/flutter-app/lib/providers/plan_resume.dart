import '../models/plan_message.dart';
import '../services/chats_api_service.dart';
import 'plan_provider.dart';

/// Fetches a persisted conversation transcript and rehydrates it into [plan]
/// (specs/continue-where-you-left-off). Shared by the home-screen Continue
/// card and the /plan/<chatId> URL restore (specs/url-page-persistence).
///
/// False on any failure — including the expected 404s for ids with no stored
/// transcript (trip-bound, anonymous, graduated, or someone else's chat).
/// Callers decide how loud to be; the URL restore degrades silently.
Future<bool> resumePlanChat({
  required ChatsApiService chats,
  required PlanNotifier plan,
  required String chatId,
}) async {
  try {
    final detail = await chats.getChat(chatId);
    plan.resumeConversation(
      chatId: detail.chatId,
      summary: detail.summary,
      messages: [
        for (final m in detail.messages)
          PlanMessage(
            role: m.role == 'user' ? MessageRole.user : MessageRole.assistant,
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
    return true;
  } catch (_) {
    return false;
  }
}
