// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hotel_stay.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

HotelStay _$HotelStayFromJson(Map<String, dynamic> json) => HotelStay(
      name: json['name'] as String,
      kind: json['kind'] as String? ?? 'hotel',
      starClass: (json['star_class'] as num?)?.toInt(),
      rating: (json['rating'] as num?)?.toDouble(),
      reviews: (json['reviews'] as num?)?.toInt(),
      ratePerNight: (json['rate_per_night'] as num?)?.toDouble(),
      totalRate: (json['total_rate'] as num?)?.toDouble(),
      currency: json['currency'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      address: json['address'] as String? ?? '',
      imageUrl: json['image_url'] as String? ?? '',
      photoRef: json['photo_ref'] as String? ?? '',
      bookingUrl: json['booking_url'] as String? ?? '',
      amenities: (json['amenities'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      checkInTime: json['check_in_time'] as String? ?? '',
      checkOutTime: json['check_out_time'] as String? ?? '',
    );

Map<String, dynamic> _$HotelStayToJson(HotelStay instance) => <String, dynamic>{
      'name': instance.name,
      'kind': instance.kind,
      'star_class': instance.starClass,
      'rating': instance.rating,
      'reviews': instance.reviews,
      'rate_per_night': instance.ratePerNight,
      'total_rate': instance.totalRate,
      'currency': instance.currency,
      'latitude': instance.latitude,
      'longitude': instance.longitude,
      'address': instance.address,
      'image_url': instance.imageUrl,
      'photo_ref': instance.photoRef,
      'booking_url': instance.bookingUrl,
      'amenities': instance.amenities,
      'check_in_time': instance.checkInTime,
      'check_out_time': instance.checkOutTime,
    };
