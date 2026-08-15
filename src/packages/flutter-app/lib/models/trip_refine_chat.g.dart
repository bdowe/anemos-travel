// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trip_refine_chat.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TripRefineChat _$TripRefineChatFromJson(Map<String, dynamic> json) =>
    TripRefineChat(
      messageCount: (json['message_count'] as num).toInt(),
      preview: json['preview'] as String,
      updatedAt: json['updated_at'] as String,
    );

Map<String, dynamic> _$TripRefineChatToJson(TripRefineChat instance) =>
    <String, dynamic>{
      'message_count': instance.messageCount,
      'preview': instance.preview,
      'updated_at': instance.updatedAt,
    };

TripRefineChatDetail _$TripRefineChatDetailFromJson(
        Map<String, dynamic> json) =>
    TripRefineChatDetail(
      tripId: json['trip_id'] as String,
      summary: json['summary'] as String,
      messages: (json['messages'] as List<dynamic>)
          .map((e) => ChatSessionMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      messageCount: (json['message_count'] as num).toInt(),
      updatedAt: json['updated_at'] as String,
    );

Map<String, dynamic> _$TripRefineChatDetailToJson(
        TripRefineChatDetail instance) =>
    <String, dynamic>{
      'trip_id': instance.tripId,
      'summary': instance.summary,
      'messages': instance.messages.map((e) => e.toJson()).toList(),
      'message_count': instance.messageCount,
      'updated_at': instance.updatedAt,
    };
