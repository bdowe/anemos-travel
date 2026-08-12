// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trip.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Trip _$TripFromJson(Map<String, dynamic> json) => Trip(
      id: json['id'] as String,
      title: json['title'] as String,
      summary: json['summary'] as String?,
      startDate: json['start_date'] as String?,
      endDate: json['end_date'] as String?,
      chatId: json['chat_id'] as String?,
      travelMode: json['travel_mode'] as String?,
      versionCount: (json['version_count'] as num?)?.toInt(),
      cities:
          (json['cities'] as List<dynamic>?)?.map((e) => e as String).toList(),
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
      items: (json['items'] as List<dynamic>?)
          ?.map((e) => ItineraryItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      accommodations: (json['accommodations'] as List<dynamic>?)
          ?.map((e) => Accommodation.fromJson(e as Map<String, dynamic>))
          .toList(),
      segments: (json['segments'] as List<dynamic>?)
          ?.map((e) => TripSegment.fromJson(e as Map<String, dynamic>))
          .toList(),
      bookingTodos: (json['booking_todos'] as List<dynamic>?)
          ?.map((e) => BookingTodo.fromJson(e as Map<String, dynamic>))
          .toList(),
      access: json['access'] as String?,
      ownerName: json['owner_name'] as String?,
      updatedByName: json['updated_by_name'] as String?,
      shared: json['shared'] as bool?,
      legs: (json['legs'] as List<dynamic>?)
          ?.map((e) => TripLegDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$TripToJson(Trip instance) => <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'summary': instance.summary,
      'start_date': instance.startDate,
      'end_date': instance.endDate,
      'chat_id': instance.chatId,
      'travel_mode': instance.travelMode,
      'version_count': instance.versionCount,
      'cities': instance.cities,
      'created_at': instance.createdAt,
      'updated_at': instance.updatedAt,
      'items': instance.items?.map((e) => e.toJson()).toList(),
      'accommodations':
          instance.accommodations?.map((e) => e.toJson()).toList(),
      'segments': instance.segments?.map((e) => e.toJson()).toList(),
      'booking_todos': instance.bookingTodos?.map((e) => e.toJson()).toList(),
      'access': instance.access,
      'owner_name': instance.ownerName,
      'updated_by_name': instance.updatedByName,
      'shared': instance.shared,
      'legs': instance.legs?.map((e) => e.toJson()).toList(),
    };
