// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trip_finding.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TripFinding _$TripFindingFromJson(Map<String, dynamic> json) => TripFinding(
      severity: json['severity'] as String,
      category: json['category'] as String,
      message: json['message'] as String,
      tripId: json['trip_id'] as String,
      day: (json['day'] as num?)?.toInt(),
      itemId: json['item_id'] as String?,
      fix: json['fix'] == null
          ? null
          : FindingFix.fromJson(json['fix'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$TripFindingToJson(TripFinding instance) =>
    <String, dynamic>{
      'severity': instance.severity,
      'category': instance.category,
      'message': instance.message,
      'trip_id': instance.tripId,
      'day': instance.day,
      'item_id': instance.itemId,
      'fix': instance.fix,
    };

FindingFix _$FindingFixFromJson(Map<String, dynamic> json) => FindingFix(
      action: json['action'] as String,
      label: json['label'] as String,
      itemId: json['item_id'] as String?,
      entityType: json['entity_type'] as String?,
      targetDay: (json['target_day'] as num?)?.toInt(),
      city: json['city'] as String?,
      origin: json['origin'] as String?,
      destination: json['destination'] as String?,
      targetOrigin: json['target_origin'] as String?,
      targetDestination: json['target_destination'] as String?,
      checkIn: json['check_in'] as String?,
      checkOut: json['check_out'] as String?,
      date: json['date'] as String?,
      mode: json['mode'] as String?,
      packingItem: json['packing_item'] as String?,
      packingCategory: json['packing_category'] as String?,
    );

Map<String, dynamic> _$FindingFixToJson(FindingFix instance) =>
    <String, dynamic>{
      'action': instance.action,
      'label': instance.label,
      'item_id': instance.itemId,
      'entity_type': instance.entityType,
      'target_day': instance.targetDay,
      'city': instance.city,
      'origin': instance.origin,
      'destination': instance.destination,
      'target_origin': instance.targetOrigin,
      'target_destination': instance.targetDestination,
      'check_in': instance.checkIn,
      'check_out': instance.checkOut,
      'date': instance.date,
      'mode': instance.mode,
      'packing_item': instance.packingItem,
      'packing_category': instance.packingCategory,
    };

TripReview _$TripReviewFromJson(Map<String, dynamic> json) => TripReview(
      findings: (json['findings'] as List<dynamic>)
          .map((e) => TripFinding.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextStep: json['next_step'] == null
          ? null
          : NextStep.fromJson(json['next_step'] as Map<String, dynamic>),
      planProgress: json['plan_progress'] == null
          ? null
          : PlanProgress.fromJson(
              json['plan_progress'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$TripReviewToJson(TripReview instance) =>
    <String, dynamic>{
      'findings': instance.findings,
      'next_step': instance.nextStep,
      'plan_progress': instance.planProgress,
    };

NextStep _$NextStepFromJson(Map<String, dynamic> json) => NextStep(
      kind: json['kind'] as String,
      title: json['title'] as String,
      detail: json['detail'] as String?,
      day: (json['day'] as num?)?.toInt(),
      count: (json['count'] as num?)?.toInt(),
      fix: json['fix'] == null
          ? null
          : FindingFix.fromJson(json['fix'] as Map<String, dynamic>),
      seedPrompt: json['seed_prompt'] as String?,
    );

Map<String, dynamic> _$NextStepToJson(NextStep instance) => <String, dynamic>{
      'kind': instance.kind,
      'title': instance.title,
      'detail': instance.detail,
      'day': instance.day,
      'count': instance.count,
      'fix': instance.fix,
      'seed_prompt': instance.seedPrompt,
    };

PlanProgress _$PlanProgressFromJson(Map<String, dynamic> json) => PlanProgress(
      done: (json['done'] as num).toInt(),
      total: (json['total'] as num).toInt(),
      phases: (json['phases'] as List<dynamic>?)
              ?.map((e) => PlanPhase.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );

Map<String, dynamic> _$PlanProgressToJson(PlanProgress instance) =>
    <String, dynamic>{
      'done': instance.done,
      'total': instance.total,
      'phases': instance.phases,
    };

PlanPhase _$PlanPhaseFromJson(Map<String, dynamic> json) => PlanPhase(
      id: json['id'] as String,
      label: json['label'] as String,
      progress: json['progress'] == null
          ? null
          : PhaseProgress.fromJson(json['progress'] as Map<String, dynamic>),
      count: (json['count'] as num?)?.toInt(),
    );

Map<String, dynamic> _$PlanPhaseToJson(PlanPhase instance) => <String, dynamic>{
      'id': instance.id,
      'label': instance.label,
      'progress': instance.progress,
      'count': instance.count,
    };

PhaseProgress _$PhaseProgressFromJson(Map<String, dynamic> json) =>
    PhaseProgress(
      done: (json['done'] as num).toInt(),
      total: (json['total'] as num).toInt(),
    );

Map<String, dynamic> _$PhaseProgressToJson(PhaseProgress instance) =>
    <String, dynamic>{
      'done': instance.done,
      'total': instance.total,
    };
