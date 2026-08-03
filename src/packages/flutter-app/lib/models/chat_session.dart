import 'package:json_annotation/json_annotation.dart';

part 'chat_session.g.dart';

/// One resumable AI-planning conversation ("continue where you left off").
/// Summary rows come from GET /chats; the full transcript from GET /chats/{id}.
@JsonSerializable()
class ChatSessionSummary {
  @JsonKey(name: 'chat_id')
  final String chatId;
  final String title;
  final String preview;
  @JsonKey(name: 'message_count')
  final int messageCount;
  @JsonKey(name: 'created_at')
  final String createdAt;
  @JsonKey(name: 'updated_at')
  final String updatedAt;

  const ChatSessionSummary({
    required this.chatId,
    required this.title,
    required this.preview,
    required this.messageCount,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ChatSessionSummary.fromJson(Map<String, dynamic> json) =>
      _$ChatSessionSummaryFromJson(json);
  Map<String, dynamic> toJson() => _$ChatSessionSummaryToJson(this);
}

/// Marker for an image that was attached to a persisted message. The server
/// strips pixel data before storing transcripts, so only the media type
/// survives — enough to render an "Image" placeholder chip on resume.
@JsonSerializable()
class ChatSessionImage {
  @JsonKey(name: 'media_type')
  final String mediaType;

  const ChatSessionImage({required this.mediaType});

  factory ChatSessionImage.fromJson(Map<String, dynamic> json) =>
      _$ChatSessionImageFromJson(json);
  Map<String, dynamic> toJson() => _$ChatSessionImageToJson(this);
}

@JsonSerializable(explicitToJson: true)
class ChatSessionMessage {
  final String role;
  final String content;
  @JsonKey(defaultValue: <ChatSessionImage>[])
  final List<ChatSessionImage> images;

  /// Compact chip label for machine-built seed messages (near-me coordinates).
  /// Round-tripped through the persisted transcript so a resumed chat renders
  /// the seed chip instead of the raw message bubble.
  @JsonKey(name: 'display_label')
  final String? displayLabel;

  const ChatSessionMessage({
    required this.role,
    required this.content,
    this.images = const [],
    this.displayLabel,
  });

  factory ChatSessionMessage.fromJson(Map<String, dynamic> json) =>
      _$ChatSessionMessageFromJson(json);
  Map<String, dynamic> toJson() => _$ChatSessionMessageToJson(this);
}

@JsonSerializable(explicitToJson: true)
class ChatSessionDetail {
  @JsonKey(name: 'chat_id')
  final String chatId;
  final String title;

  /// Running compaction summary; empty when the conversation was never
  /// compacted. Restored as the resumed session's compactedSummary.
  final String summary;
  final List<ChatSessionMessage> messages;
  @JsonKey(name: 'updated_at')
  final String updatedAt;

  const ChatSessionDetail({
    required this.chatId,
    required this.title,
    required this.summary,
    required this.messages,
    required this.updatedAt,
  });

  factory ChatSessionDetail.fromJson(Map<String, dynamic> json) =>
      _$ChatSessionDetailFromJson(json);
  Map<String, dynamic> toJson() => _$ChatSessionDetailToJson(this);
}
