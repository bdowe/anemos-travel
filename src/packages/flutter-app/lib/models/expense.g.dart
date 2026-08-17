// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'expense.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Expense _$ExpenseFromJson(Map<String, dynamic> json) => Expense(
      id: json['id'] as String,
      category: json['category'] as String,
      label: json['label'] as String,
      amount: (json['amount'] as num).toDouble(),
      plannedAmount: (json['planned_amount'] as num?)?.toDouble(),
      actualAmount: (json['actual_amount'] as num?)?.toDouble(),
      purchased: json['purchased'] as bool? ?? true,
      position: (json['position'] as num?)?.toInt() ?? 0,
      auto: json['auto'] as bool? ?? false,
      sourceKind: json['source_kind'] as String?,
      sourceId: json['source_id'] as String?,
      legKey: json['leg_key'] as String?,
    );

Map<String, dynamic> _$ExpenseToJson(Expense instance) => <String, dynamic>{
      'id': instance.id,
      'category': instance.category,
      'label': instance.label,
      'amount': instance.amount,
      'planned_amount': instance.plannedAmount,
      'actual_amount': instance.actualAmount,
      'purchased': instance.purchased,
      'position': instance.position,
      'auto': instance.auto,
      'source_kind': instance.sourceKind,
      'source_id': instance.sourceId,
      'leg_key': instance.legKey,
    };
