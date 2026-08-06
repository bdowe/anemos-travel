// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trip_leg_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TripLegDto _$TripLegDtoFromJson(Map<String, dynamic> json) => TripLegDto(
      key: json['key'] as String,
      label: json['label'] as String,
      hub: json['hub'] as String?,
      startDate: json['start_date'] as String?,
      endDate: json['end_date'] as String?,
      dateSource: json['date_source'] as String?,
      zeroNight: json['zero_night'] as bool?,
      firstPosition: (json['first_position'] as num).toInt(),
      lastPosition: (json['last_position'] as num).toInt(),
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$TripLegDtoToJson(TripLegDto instance) =>
    <String, dynamic>{
      'key': instance.key,
      'label': instance.label,
      'hub': instance.hub,
      'start_date': instance.startDate,
      'end_date': instance.endDate,
      'date_source': instance.dateSource,
      'zero_night': instance.zeroNight,
      'first_position': instance.firstPosition,
      'last_position': instance.lastPosition,
      'lat': instance.lat,
      'lng': instance.lng,
    };
