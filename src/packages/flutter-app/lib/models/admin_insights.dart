import 'package:json_annotation/json_annotation.dart';

part 'admin_insights.g.dart';

/// Models for the admin dashboard extensions (GET /admin/metrics/timeseries,
/// /totals, /activity, /users). Kept separate from [AdminMetrics] so the
/// original /admin/metrics contract stays untouched.

/// One UTC day bucket in a trend series. Days with zero events are absent
/// from the API payload; [AdminTimeseries.denseSeries] fills the gaps.
@JsonSerializable()
class DailyCount {
  /// Parsed from YYYY-MM-DD — a UTC calendar day.
  final DateTime day;
  final int n;

  const DailyCount({required this.day, this.n = 0});

  factory DailyCount.fromJson(Map<String, dynamic> json) =>
      _$DailyCountFromJson(json);
  Map<String, dynamic> toJson() => _$DailyCountToJson(this);
}

/// Mirror of /admin/metrics/timeseries: sparse daily buckets per event type.
/// Every dashboard series key is always present (empty list included), so the
/// Trends tab renders stable chart slots.
@JsonSerializable()
class AdminTimeseries {
  final int days;
  @JsonKey(name: 'start_day')
  final DateTime startDay;
  final Map<String, List<DailyCount>> series;

  const AdminTimeseries({
    this.days = 30,
    required this.startDay,
    this.series = const {},
  });

  /// The sparse series for [key] expanded to one entry per day of the window,
  /// zero-filled. Chart-ready: length is always [days].
  ///
  /// Days are compared as UTC calendar dates: DateTime.parse on the API's
  /// bare "YYYY-MM-DD" yields a LOCAL midnight, which would never equal a
  /// DateTime.utc key, so both sides are normalized through [_utcDay].
  List<DailyCount> denseSeries(String key) {
    final byDay = <DateTime, int>{
      for (final c in series[key] ?? const <DailyCount>[]) _utcDay(c.day): c.n,
    };
    return List.generate(days, (i) {
      final day = DateTime.utc(startDay.year, startDay.month, startDay.day + i);
      return DailyCount(day: day, n: byDay[day] ?? 0);
    });
  }

  static DateTime _utcDay(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  factory AdminTimeseries.fromJson(Map<String, dynamic> json) =>
      _$AdminTimeseriesFromJson(json);
  Map<String, dynamic> toJson() => _$AdminTimeseriesToJson(this);
}

/// Mirror of /admin/metrics/totals: all-time counts straight off the domain
/// tables — not scoped to a days window, unlike [AdminMetrics].
@JsonSerializable()
class AdminTotals {
  final int users;
  @JsonKey(name: 'verified_users')
  final int verifiedUsers;
  @JsonKey(name: 'onboarded_users')
  final int onboardedUsers;
  final int trips;

  /// Distinct trip lineages (COALESCE(chat_id, id) — the My Trips grouping).
  @JsonKey(name: 'trip_lineages')
  final int tripLineages;
  @JsonKey(name: 'itinerary_items')
  final int itineraryItems;
  @JsonKey(name: 'booking_todos')
  final int bookingTodos;
  @JsonKey(name: 'published_local_recs')
  final int publishedLocalRecs;
  @JsonKey(name: 'local_guides')
  final int localGuides;
  @JsonKey(name: 'active_collaborators')
  final int activeCollaborators;
  @JsonKey(name: 'active_shares')
  final int activeShares;
  @JsonKey(name: 'active_sessions')
  final int activeSessions;
  @JsonKey(name: 'analytics_events')
  final int analyticsEvents;

  const AdminTotals({
    this.users = 0,
    this.verifiedUsers = 0,
    this.onboardedUsers = 0,
    this.trips = 0,
    this.tripLineages = 0,
    this.itineraryItems = 0,
    this.bookingTodos = 0,
    this.publishedLocalRecs = 0,
    this.localGuides = 0,
    this.activeCollaborators = 0,
    this.activeShares = 0,
    this.activeSessions = 0,
    this.analyticsEvents = 0,
  });

  factory AdminTotals.fromJson(Map<String, dynamic> json) =>
      _$AdminTotalsFromJson(json);
  Map<String, dynamic> toJson() => _$AdminTotalsToJson(this);
}

/// One row of the activity tail. [userEmail] is null for anonymous events
/// (the API keys anonymity off user_id, never an empty email).
@JsonSerializable()
class AdminActivityEvent {
  final String id;
  @JsonKey(name: 'event_type')
  final String eventType;
  @JsonKey(name: 'user_email')
  final String? userEmail;
  @JsonKey(name: 'user_is_admin')
  final bool userIsAdmin;
  @JsonKey(name: 'trip_id')
  final String? tripId;

  /// Sanitized-at-ingest metadata (provider, surface, source, …), echoed
  /// verbatim by the API. Null when the event carried none.
  final Map<String, dynamic>? metadata;
  @JsonKey(name: 'created_at')
  final DateTime createdAt;

  const AdminActivityEvent({
    required this.id,
    required this.eventType,
    this.userEmail,
    this.userIsAdmin = false,
    this.tripId,
    this.metadata,
    required this.createdAt,
  });

  factory AdminActivityEvent.fromJson(Map<String, dynamic> json) =>
      _$AdminActivityEventFromJson(json);
  Map<String, dynamic> toJson() => _$AdminActivityEventToJson(this);
}

/// Mirror of /admin/metrics/activity: one page of the event tail plus the
/// keyset cursor for the next page (null on the last page).
@JsonSerializable()
class AdminActivityFeed {
  final List<AdminActivityEvent> events;
  @JsonKey(name: 'next_before')
  final String? nextBefore;

  const AdminActivityFeed({this.events = const [], this.nextBefore});

  factory AdminActivityFeed.fromJson(Map<String, dynamic> json) =>
      _$AdminActivityFeedFromJson(json);
  Map<String, dynamic> toJson() => _$AdminActivityFeedToJson(this);
}

/// One row of /admin/metrics/users: a user plus their activity aggregates.
@JsonSerializable()
class AdminUserRow {
  final String id;
  final String email;
  @JsonKey(name: 'display_name')
  final String? displayName;
  @JsonKey(name: 'is_admin')
  final bool isAdmin;
  @JsonKey(name: 'signed_up_at')
  final DateTime signedUpAt;
  final bool onboarded;
  @JsonKey(name: 'email_verified')
  final bool emailVerified;
  final int trips;
  @JsonKey(name: 'trip_lineages')
  final int tripLineages;
  @JsonKey(name: 'plan_sessions')
  final int planSessions;
  @JsonKey(name: 'booking_clicks')
  final int bookingClicks;
  @JsonKey(name: 'plan_input_tokens')
  final int planInputTokens;
  @JsonKey(name: 'plan_output_tokens')
  final int planOutputTokens;
  @JsonKey(name: 'plan_cache_read_tokens')
  final int planCacheReadTokens;
  @JsonKey(name: 'plan_cache_creation_tokens')
  final int planCacheCreationTokens;

  /// Same pricing basis as [AdminMetrics.estClaudeCostUsd] — estimate only.
  @JsonKey(name: 'est_claude_cost_usd')
  final double estClaudeCostUsd;

  /// Null for users with no analytics events yet.
  @JsonKey(name: 'last_event_at')
  final DateTime? lastEventAt;

  const AdminUserRow({
    required this.id,
    required this.email,
    this.displayName,
    this.isAdmin = false,
    required this.signedUpAt,
    this.onboarded = false,
    this.emailVerified = false,
    this.trips = 0,
    this.tripLineages = 0,
    this.planSessions = 0,
    this.bookingClicks = 0,
    this.planInputTokens = 0,
    this.planOutputTokens = 0,
    this.planCacheReadTokens = 0,
    this.planCacheCreationTokens = 0,
    this.estClaudeCostUsd = 0,
    this.lastEventAt,
  });

  factory AdminUserRow.fromJson(Map<String, dynamic> json) =>
      _$AdminUserRowFromJson(json);
  Map<String, dynamic> toJson() => _$AdminUserRowToJson(this);
}

/// Mirror of /admin/metrics/users: one offset page plus the all-time total.
@JsonSerializable()
class AdminUserList {
  final int total;
  final List<AdminUserRow> users;

  const AdminUserList({this.total = 0, this.users = const []});

  factory AdminUserList.fromJson(Map<String, dynamic> json) =>
      _$AdminUserListFromJson(json);
  Map<String, dynamic> toJson() => _$AdminUserListToJson(this);
}
