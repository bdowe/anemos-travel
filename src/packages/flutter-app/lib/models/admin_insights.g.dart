// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'admin_insights.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DailyCount _$DailyCountFromJson(Map<String, dynamic> json) => DailyCount(
      day: DateTime.parse(json['day'] as String),
      n: (json['n'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$DailyCountToJson(DailyCount instance) =>
    <String, dynamic>{
      'day': instance.day.toIso8601String(),
      'n': instance.n,
    };

AdminTimeseries _$AdminTimeseriesFromJson(Map<String, dynamic> json) =>
    AdminTimeseries(
      days: (json['days'] as num?)?.toInt() ?? 30,
      startDay: DateTime.parse(json['start_day'] as String),
      series: (json['series'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(
                k,
                (e as List<dynamic>)
                    .map((e) => DailyCount.fromJson(e as Map<String, dynamic>))
                    .toList()),
          ) ??
          const {},
    );

Map<String, dynamic> _$AdminTimeseriesToJson(AdminTimeseries instance) =>
    <String, dynamic>{
      'days': instance.days,
      'start_day': instance.startDay.toIso8601String(),
      'series': instance.series,
    };

AdminTotals _$AdminTotalsFromJson(Map<String, dynamic> json) => AdminTotals(
      users: (json['users'] as num?)?.toInt() ?? 0,
      verifiedUsers: (json['verified_users'] as num?)?.toInt() ?? 0,
      onboardedUsers: (json['onboarded_users'] as num?)?.toInt() ?? 0,
      trips: (json['trips'] as num?)?.toInt() ?? 0,
      tripLineages: (json['trip_lineages'] as num?)?.toInt() ?? 0,
      itineraryItems: (json['itinerary_items'] as num?)?.toInt() ?? 0,
      bookingTodos: (json['booking_todos'] as num?)?.toInt() ?? 0,
      publishedLocalRecs: (json['published_local_recs'] as num?)?.toInt() ?? 0,
      localGuides: (json['local_guides'] as num?)?.toInt() ?? 0,
      activeCollaborators: (json['active_collaborators'] as num?)?.toInt() ?? 0,
      activeShares: (json['active_shares'] as num?)?.toInt() ?? 0,
      activeSessions: (json['active_sessions'] as num?)?.toInt() ?? 0,
      analyticsEvents: (json['analytics_events'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$AdminTotalsToJson(AdminTotals instance) =>
    <String, dynamic>{
      'users': instance.users,
      'verified_users': instance.verifiedUsers,
      'onboarded_users': instance.onboardedUsers,
      'trips': instance.trips,
      'trip_lineages': instance.tripLineages,
      'itinerary_items': instance.itineraryItems,
      'booking_todos': instance.bookingTodos,
      'published_local_recs': instance.publishedLocalRecs,
      'local_guides': instance.localGuides,
      'active_collaborators': instance.activeCollaborators,
      'active_shares': instance.activeShares,
      'active_sessions': instance.activeSessions,
      'analytics_events': instance.analyticsEvents,
    };

AdminActivityEvent _$AdminActivityEventFromJson(Map<String, dynamic> json) =>
    AdminActivityEvent(
      id: json['id'] as String,
      eventType: json['event_type'] as String,
      userEmail: json['user_email'] as String?,
      userIsAdmin: json['user_is_admin'] as bool? ?? false,
      tripId: json['trip_id'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );

Map<String, dynamic> _$AdminActivityEventToJson(AdminActivityEvent instance) =>
    <String, dynamic>{
      'id': instance.id,
      'event_type': instance.eventType,
      'user_email': instance.userEmail,
      'user_is_admin': instance.userIsAdmin,
      'trip_id': instance.tripId,
      'metadata': instance.metadata,
      'created_at': instance.createdAt.toIso8601String(),
    };

AdminActivityFeed _$AdminActivityFeedFromJson(Map<String, dynamic> json) =>
    AdminActivityFeed(
      events: (json['events'] as List<dynamic>?)
              ?.map(
                  (e) => AdminActivityEvent.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      nextBefore: json['next_before'] as String?,
    );

Map<String, dynamic> _$AdminActivityFeedToJson(AdminActivityFeed instance) =>
    <String, dynamic>{
      'events': instance.events,
      'next_before': instance.nextBefore,
    };

AdminUserRow _$AdminUserRowFromJson(Map<String, dynamic> json) => AdminUserRow(
      id: json['id'] as String,
      email: json['email'] as String,
      displayName: json['display_name'] as String?,
      isAdmin: json['is_admin'] as bool? ?? false,
      signedUpAt: DateTime.parse(json['signed_up_at'] as String),
      onboarded: json['onboarded'] as bool? ?? false,
      emailVerified: json['email_verified'] as bool? ?? false,
      trips: (json['trips'] as num?)?.toInt() ?? 0,
      tripLineages: (json['trip_lineages'] as num?)?.toInt() ?? 0,
      planSessions: (json['plan_sessions'] as num?)?.toInt() ?? 0,
      bookingClicks: (json['booking_clicks'] as num?)?.toInt() ?? 0,
      planInputTokens: (json['plan_input_tokens'] as num?)?.toInt() ?? 0,
      planOutputTokens: (json['plan_output_tokens'] as num?)?.toInt() ?? 0,
      planCacheReadTokens:
          (json['plan_cache_read_tokens'] as num?)?.toInt() ?? 0,
      planCacheCreationTokens:
          (json['plan_cache_creation_tokens'] as num?)?.toInt() ?? 0,
      estClaudeCostUsd: (json['est_claude_cost_usd'] as num?)?.toDouble() ?? 0,
      lastEventAt: json['last_event_at'] == null
          ? null
          : DateTime.parse(json['last_event_at'] as String),
    );

Map<String, dynamic> _$AdminUserRowToJson(AdminUserRow instance) =>
    <String, dynamic>{
      'id': instance.id,
      'email': instance.email,
      'display_name': instance.displayName,
      'is_admin': instance.isAdmin,
      'signed_up_at': instance.signedUpAt.toIso8601String(),
      'onboarded': instance.onboarded,
      'email_verified': instance.emailVerified,
      'trips': instance.trips,
      'trip_lineages': instance.tripLineages,
      'plan_sessions': instance.planSessions,
      'booking_clicks': instance.bookingClicks,
      'plan_input_tokens': instance.planInputTokens,
      'plan_output_tokens': instance.planOutputTokens,
      'plan_cache_read_tokens': instance.planCacheReadTokens,
      'plan_cache_creation_tokens': instance.planCacheCreationTokens,
      'est_claude_cost_usd': instance.estClaudeCostUsd,
      'last_event_at': instance.lastEventAt?.toIso8601String(),
    };

AdminUserList _$AdminUserListFromJson(Map<String, dynamic> json) =>
    AdminUserList(
      total: (json['total'] as num?)?.toInt() ?? 0,
      users: (json['users'] as List<dynamic>?)
              ?.map((e) => AdminUserRow.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$AdminUserListToJson(AdminUserList instance) =>
    <String, dynamic>{
      'total': instance.total,
      'users': instance.users,
    };
