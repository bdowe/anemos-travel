import '../models/chat_session.dart';
import '../models/plan_message.dart';
import '../services/chats_api_service.dart';
import '../services/trips_api_service.dart';
import 'plan_provider.dart';

/// Turns a persisted transcript into chat state. The ONE mapping, shared by
/// both resume paths — the freeform plan chat below and the per-trip refine
/// chat ([resumeTripRefineChat]) — so a stored conversation can never render
/// differently depending on which surface reopened it.
List<PlanMessage> planMessagesFrom(List<ChatSessionMessage> messages) => [
      for (final m in messages)
        PlanMessage(
          role: m.role == 'user' ? MessageRole.user : MessageRole.assistant,
          content: m.content,
          // Restores the seed context chip (e.g. "Near my current location",
          // "Refining Day 2 — Athens") instead of the raw message bubble.
          displayLabel: m.displayLabel,
          // Pixels are stripped server-side; null bytes renders the
          // "Image" placeholder chip and stays out of resent history.
          attachments: [
            for (final img in m.images)
              PlanAttachment(bytes: null, mediaType: img.mediaType),
          ],
        ),
    ];

/// Fetches a persisted conversation transcript and rehydrates it into [plan]
/// (specs/continue-where-you-left-off). Shared by the home-screen Continue
/// card and the /plan/<chatId> URL restore (specs/url-page-persistence).
///
/// False on any failure — including the expected 404s for ids with no stored
/// transcript (anonymous, graduated, or someone else's chat). Callers decide
/// how loud to be; the URL restore degrades silently.
///
/// A trip's own conversation is deliberately unreachable here: it has no chat
/// id at all (specs/trip-refine-memory), so no value of [chatId] can name one
/// and resuming it into the unbound Agent tab — which would drop the trip
/// binding — is impossible rather than merely guarded against.
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
      messages: planMessagesFrom(detail.messages),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// Rehydrates a trip's own saved conversation into its refine-panel notifier
/// (specs/trip-refine-memory).
///
/// Unlike [resumePlanChat] this **rethrows**: the panel has to tell "this
/// conversation expired" from "we couldn't reach it", and — more importantly —
/// a caller must never proceed to send a message onto an empty panel after a
/// failed restore. The transcript is upserted wholesale each turn, so that
/// would overwrite a long conversation with two messages.
///
/// Passes no chat id: a refine conversation has none, and the throwaway one the
/// next send mints is ignored by the server for a bound turn.
Future<void> resumeTripRefineChat({
  required TripsApiService trips,
  required PlanNotifier plan,
  required String tripId,
}) async {
  final detail = await trips.getTripRefineChat(tripId);
  plan.resumeConversation(
    summary: detail.summary,
    messages: planMessagesFrom(detail.messages),
  );
}
