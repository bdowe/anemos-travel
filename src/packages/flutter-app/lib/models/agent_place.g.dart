// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'agent_place.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AgentPlace _$AgentPlaceFromJson(Map<String, dynamic> json) => AgentPlace(
      name: json['name'] as String,
      placeId: json['place_id'] as String? ?? '',
      address: json['address'] as String? ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0,
      rating: (json['rating'] as num?)?.toDouble(),
      priceLevel: (json['price_level'] as num?)?.toInt(),
      category: json['category'] as String? ?? '',
      photoRef: json['photo_ref'] as String? ?? '',
      photoAttribution: json['photo_attribution'] as String? ?? '',
      freeListed: json['free_listed'] as bool? ?? false,
    );

Map<String, dynamic> _$AgentPlaceToJson(AgentPlace instance) =>
    <String, dynamic>{
      'name': instance.name,
      'place_id': instance.placeId,
      'address': instance.address,
      'lat': instance.lat,
      'lng': instance.lng,
      'rating': instance.rating,
      'price_level': instance.priceLevel,
      'category': instance.category,
      'photo_ref': instance.photoRef,
      'photo_attribution': instance.photoAttribution,
      'free_listed': instance.freeListed,
    };
