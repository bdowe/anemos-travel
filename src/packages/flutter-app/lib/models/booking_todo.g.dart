// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'booking_todo.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BookingTodo _$BookingTodoFromJson(Map<String, dynamic> json) => BookingTodo(
      id: json['id'] as String,
      kind: json['kind'] as String,
      todoKey: json['todo_key'] as String,
      title: json['title'] as String,
      subtitle: json['subtitle'] as String?,
      provider: json['provider'] as String?,
      searchUrl: json['search_url'] as String?,
      departDate: json['depart_date'] as String?,
      returnDate: json['return_date'] as String?,
      mode: json['mode'] as String?,
      booked: json['booked'] as bool? ?? false,
      auto: json['auto'] as bool? ?? true,
      position: (json['position'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$BookingTodoToJson(BookingTodo instance) =>
    <String, dynamic>{
      'id': instance.id,
      'kind': instance.kind,
      'todo_key': instance.todoKey,
      'title': instance.title,
      'subtitle': instance.subtitle,
      'provider': instance.provider,
      'search_url': instance.searchUrl,
      'depart_date': instance.departDate,
      'return_date': instance.returnDate,
      'mode': instance.mode,
      'booked': instance.booked,
      'auto': instance.auto,
      'position': instance.position,
    };
