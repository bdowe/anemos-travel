// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ops_uptime.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UptimeDay _$UptimeDayFromJson(Map<String, dynamic> json) => UptimeDay(
      day: json['day'] as String? ?? '',
      state: json['state'] as String? ?? 'no_data',
      uptimePct: (json['uptime_pct'] as num?)?.toDouble(),
      upS: (json['up_s'] as num?)?.toInt() ?? 0,
      downS: (json['down_s'] as num?)?.toInt() ?? 0,
      unknownS: (json['unknown_s'] as num?)?.toInt() ?? 0,
      reasonCodes: (json['reason_codes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );

Map<String, dynamic> _$UptimeDayToJson(UptimeDay instance) => <String, dynamic>{
      'day': instance.day,
      'state': instance.state,
      'uptime_pct': instance.uptimePct,
      'up_s': instance.upS,
      'down_s': instance.downS,
      'unknown_s': instance.unknownS,
      'reason_codes': instance.reasonCodes,
    };

UptimeComponent _$UptimeComponentFromJson(Map<String, dynamic> json) =>
    UptimeComponent(
      key: json['key'] as String? ?? '',
      status: json['status'] as String? ?? 'no_data',
      uptimePct: (json['uptime_pct'] as num?)?.toDouble(),
      observedDays: (json['observed_days'] as num?)?.toInt() ?? 0,
      days: (json['days'] as List<dynamic>?)
              ?.map((e) => UptimeDay.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$UptimeComponentToJson(UptimeComponent instance) =>
    <String, dynamic>{
      'key': instance.key,
      'status': instance.status,
      'uptime_pct': instance.uptimePct,
      'observed_days': instance.observedDays,
      'days': instance.days,
    };

OpsUptime _$OpsUptimeFromJson(Map<String, dynamic> json) => OpsUptime(
      days: (json['days'] as num?)?.toInt() ?? 0,
      startDay: json['start_day'] as String? ?? '',
      monitoringSince: json['monitoring_since'] == null
          ? null
          : DateTime.parse(json['monitoring_since'] as String),
      components: (json['components'] as List<dynamic>?)
              ?.map((e) => UptimeComponent.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$OpsUptimeToJson(OpsUptime instance) => <String, dynamic>{
      'days': instance.days,
      'start_day': instance.startDay,
      'monitoring_since': instance.monitoringSince?.toIso8601String(),
      'components': instance.components,
    };
