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
      itemCount: (json['item_count'] as num?)?.toInt(),
      bookingTotal: (json['booking_total'] as num?)?.toInt(),
      bookingBooked: (json['booking_booked'] as num?)?.toInt(),
      stayTotal: (json['stay_total'] as num?)?.toInt(),
      stayBooked: (json['stay_booked'] as num?)?.toInt(),
      packingTotal: (json['packing_total'] as num?)?.toInt(),
      packingDone: (json['packing_done'] as num?)?.toInt(),
      budgetTarget: (json['budget_target'] as num?)?.toDouble(),
      budgetSpent: (json['budget_spent'] as num?)?.toDouble(),
      budgetCurrency: json['budget_currency'] as String?,
      nextTransportDepart: json['next_transport_depart'] as String?,
      cityPins: (json['city_pins'] as List<dynamic>?)
          ?.map((e) => CityPin.fromJson(e as Map<String, dynamic>))
          .toList(),
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
      'item_count': instance.itemCount,
      'booking_total': instance.bookingTotal,
      'booking_booked': instance.bookingBooked,
      'stay_total': instance.stayTotal,
      'stay_booked': instance.stayBooked,
      'packing_total': instance.packingTotal,
      'packing_done': instance.packingDone,
      'budget_target': instance.budgetTarget,
      'budget_spent': instance.budgetSpent,
      'budget_currency': instance.budgetCurrency,
      'next_transport_depart': instance.nextTransportDepart,
      'city_pins': instance.cityPins?.map((e) => e.toJson()).toList(),
      'legs': instance.legs?.map((e) => e.toJson()).toList(),
    };
