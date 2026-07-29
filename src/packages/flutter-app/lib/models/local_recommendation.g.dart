// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_recommendation.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LocalRecommendation _$LocalRecommendationFromJson(Map<String, dynamic> json) =>
    LocalRecommendation(
      id: json['id'] as String,
      name: json['name'] as String,
      city: json['city'] as String? ?? '',
      neighborhood: json['neighborhood'] as String? ?? '',
      category: json['category'] as String? ?? '',
      address: json['address'] as String? ?? '',
      placeId: json['place_id'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      tip: json['tip'] as String? ?? '',
      quote: json['quote'] as String? ?? '',
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
              [],
      sourceName: json['source_name'] as String? ?? '',
      sourceBio: json['source_bio'] as String? ?? '',
      sourcePhotoUrl: json['source_photo_url'] as String? ?? '',
      sourceExpertise: json['source_expertise'] as String? ?? '',
      sourceCredibility: json['source_credibility'] as String? ?? '',
      photoRef: json['photo_ref'] as String? ?? '',
      photoAttribution: json['photo_attribution'] as String? ?? '',
    );

Map<String, dynamic> _$LocalRecommendationToJson(
        LocalRecommendation instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'city': instance.city,
      'neighborhood': instance.neighborhood,
      'category': instance.category,
      'address': instance.address,
      'place_id': instance.placeId,
      'latitude': instance.latitude,
      'longitude': instance.longitude,
      'tip': instance.tip,
      'quote': instance.quote,
      'tags': instance.tags,
      'source_name': instance.sourceName,
      'source_bio': instance.sourceBio,
      'source_photo_url': instance.sourcePhotoUrl,
      'source_expertise': instance.sourceExpertise,
      'source_credibility': instance.sourceCredibility,
      'photo_ref': instance.photoRef,
      'photo_attribution': instance.photoAttribution,
    };
