// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'budget.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Budget _$BudgetFromJson(Map<String, dynamic> json) => Budget(
      targetAmount: (json['target_amount'] as num?)?.toDouble(),
      currency: json['currency'] as String? ?? 'USD',
      spent: (json['spent'] as num?)?.toDouble() ?? 0,
      remaining: (json['remaining'] as num?)?.toDouble(),
      planned: (json['planned'] as num?)?.toDouble(),
      projected: (json['projected'] as num?)?.toDouble(),
      planVariance: (json['plan_variance'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$BudgetToJson(Budget instance) => <String, dynamic>{
      'target_amount': instance.targetAmount,
      'currency': instance.currency,
      'spent': instance.spent,
      'remaining': instance.remaining,
      'planned': instance.planned,
      'projected': instance.projected,
      'plan_variance': instance.planVariance,
    };
