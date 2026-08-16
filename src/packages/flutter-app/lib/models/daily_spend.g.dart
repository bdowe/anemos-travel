// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'daily_spend.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DailySpendGuide _$DailySpendGuideFromJson(Map<String, dynamic> json) =>
    DailySpendGuide(
      currency: json['currency'] as String? ?? 'USD',
      tier: json['tier'] as String? ?? 'mid',
      tierSource: json['tier_source'] as String? ?? 'default',
      basis: json['basis'] as String? ?? 'estimate',
      cities: (json['cities'] as List<dynamic>?)
              ?.map((e) => DailySpendCity.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      unavailableReason: json['unavailable_reason'] as String?,
    );

Map<String, dynamic> _$DailySpendGuideToJson(DailySpendGuide instance) =>
    <String, dynamic>{
      'currency': instance.currency,
      'tier': instance.tier,
      'tier_source': instance.tierSource,
      'basis': instance.basis,
      'cities': instance.cities.map((e) => e.toJson()).toList(),
      'unavailable_reason': instance.unavailableReason,
    };

DailySpendCity _$DailySpendCityFromJson(Map<String, dynamic> json) =>
    DailySpendCity(
      legKey: json['leg_key'] as String,
      label: json['label'] as String,
      nights: (json['nights'] as num).toInt(),
      dailyAmount: (json['daily_amount'] as num).toDouble(),
      includes: json['includes'] as String? ?? '',
    );

Map<String, dynamic> _$DailySpendCityToJson(DailySpendCity instance) =>
    <String, dynamic>{
      'leg_key': instance.legKey,
      'label': instance.label,
      'nights': instance.nights,
      'daily_amount': instance.dailyAmount,
      'includes': instance.includes,
    };
