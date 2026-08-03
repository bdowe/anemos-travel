// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_session.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ChatSessionSummary _$ChatSessionSummaryFromJson(Map<String, dynamic> json) =>
    ChatSessionSummary(
      chatId: json['chat_id'] as String,
      title: json['title'] as String,
      preview: json['preview'] as String,
      messageCount: (json['message_count'] as num).toInt(),
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
    );

Map<String, dynamic> _$ChatSessionSummaryToJson(ChatSessionSummary instance) =>
    <String, dynamic>{
      'chat_id': instance.chatId,
      'title': instance.title,
      'preview': instance.preview,
      'message_count': instance.messageCount,
      'created_at': instance.createdAt,
      'updated_at': instance.updatedAt,
    };

ChatSessionImage _$ChatSessionImageFromJson(Map<String, dynamic> json) =>
    ChatSessionImage(
      mediaType: json['media_type'] as String,
    );

Map<String, dynamic> _$ChatSessionImageToJson(ChatSessionImage instance) =>
    <String, dynamic>{
      'media_type': instance.mediaType,
    };

ChatSessionMessage _$ChatSessionMessageFromJson(Map<String, dynamic> json) =>
    ChatSessionMessage(
      role: json['role'] as String,
      content: json['content'] as String,
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => ChatSessionImage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      displayLabel: json['display_label'] as String?,
    );

Map<String, dynamic> _$ChatSessionMessageToJson(ChatSessionMessage instance) =>
    <String, dynamic>{
      'role': instance.role,
      'content': instance.content,
      'images': instance.images.map((e) => e.toJson()).toList(),
      'display_label': instance.displayLabel,
    };

ChatSessionDetail _$ChatSessionDetailFromJson(Map<String, dynamic> json) =>
    ChatSessionDetail(
      chatId: json['chat_id'] as String,
      title: json['title'] as String,
      summary: json['summary'] as String,
      messages: (json['messages'] as List<dynamic>)
          .map((e) => ChatSessionMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      updatedAt: json['updated_at'] as String,
    );

Map<String, dynamic> _$ChatSessionDetailToJson(ChatSessionDetail instance) =>
    <String, dynamic>{
      'chat_id': instance.chatId,
      'title': instance.title,
      'summary': instance.summary,
      'messages': instance.messages.map((e) => e.toJson()).toList(),
      'updated_at': instance.updatedAt,
    };
