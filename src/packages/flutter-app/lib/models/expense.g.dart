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
      position: (json['position'] as num?)?.toInt() ?? 0,
      auto: json['auto'] as bool? ?? false,
      sourceKind: json['source_kind'] as String?,
      sourceId: json['source_id'] as String?,
    );

Map<String, dynamic> _$ExpenseToJson(Expense instance) => <String, dynamic>{
      'id': instance.id,
      'category': instance.category,
      'label': instance.label,
      'amount': instance.amount,
      'position': instance.position,
      'auto': instance.auto,
      'source_kind': instance.sourceKind,
      'source_id': instance.sourceId,
    };
