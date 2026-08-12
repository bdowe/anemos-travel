import 'package:json_annotation/json_annotation.dart';

part 'admin_metrics.g.dart';

/// One provider-call counter pair: billable upstream calls vs cache hits.
/// PROCESS-LIFETIME on the API side — resets on every restart/deploy, and is
/// NOT scoped to the dashboard's days window.
@JsonSerializable()
class UpstreamCallCounts {
  final int upstream;
  @JsonKey(name: 'cache_hits')
  final int cacheHits;

  const UpstreamCallCounts({this.upstream = 0, this.cacheHits = 0});

  factory UpstreamCallCounts.fromJson(Map<String, dynamic> json) =>
      _$UpstreamCallCountsFromJson(json);
  Map<String, dynamic> toJson() => _$UpstreamCallCountsToJson(this);
}

/// Mirror of the API's places_calls_since_process_start object: per-class
/// Google Places call counters plus the estimated upstream spend (list-price
/// estimate, not a bill). Process-lifetime — see [UpstreamCallCounts].
@JsonSerializable()
class PlacesCalls {
  final UpstreamCallCounts search;
  final UpstreamCallCounts autocomplete;
  final UpstreamCallCounts details;
  @JsonKey(name: 'est_places_cost_usd')
  final double estPlacesCostUsd;

  const PlacesCalls({
    this.search = const UpstreamCallCounts(),
    this.autocomplete = const UpstreamCallCounts(),
    this.details = const UpstreamCallCounts(),
    this.estPlacesCostUsd = 0,
  });

  int get totalUpstream =>
      search.upstream + autocomplete.upstream + details.upstream;
  int get totalCacheHits =>
      search.cacheHits + autocomplete.cacheHits + details.cacheHits;

  factory PlacesCalls.fromJson(Map<String, dynamic> json) =>
      _$PlacesCallsFromJson(json);
  Map<String, dynamic> toJson() => _$PlacesCallsToJson(this);
}

/// Mirror of the API's MetricsResponse (GET /admin/metrics?days=) — the
/// Phase-1 growth funnel: activation, attach rate, retention, AI cost.
@JsonSerializable()
class AdminMetrics {
  final int days;

  /// Anonymous landing_viewed count — the top of the funnel, above signups.
  /// Directional only (unauthenticated, rate-limit bounded). Nullable: absent
  /// on API builds older than this field, and the tile is hidden then.
  @JsonKey(name: 'landing_views')
  final int? landingViews;
  final int signups;
  @JsonKey(name: 'activated_signups')
  final int activatedSignups;
  @JsonKey(name: 'activation_rate')
  final double activationRate;
  @JsonKey(name: 'onboardings_completed')
  final int onboardingsCompleted;
  @JsonKey(name: 'trips_created')
  final int tripsCreated;
  @JsonKey(name: 'trips_refined')
  final int tripsRefined;
  @JsonKey(name: 'trips_with_booking_click')
  final int tripsWithBookingClick;
  @JsonKey(name: 'attach_rate')
  final double attachRate;
  /// Total booking-link clicks, authenticated + anonymous (unchanged field).
  @JsonKey(name: 'booking_clicks')
  final int bookingClicks;

  /// The user_id-NULL slice of [bookingClicks] — signed-out clicks, rate-limit
  /// bounded but unaudited, split out so partner-facing reads can discount
  /// them. Nullable: absent on older API builds (caption hidden then).
  @JsonKey(name: 'booking_clicks_anonymous')
  final int? bookingClicksAnonymous;
  @JsonKey(name: 'clicks_by_provider')
  final Map<String, int> clicksByProvider;

  /// Anonymous slice of [clicksByProvider] (parallel map; only providers with
  /// >= 1 anonymous click appear). Nullable: absent on older API builds.
  @JsonKey(name: 'clicks_by_provider_anonymous')
  final Map<String, int>? clicksByProviderAnonymous;
  @JsonKey(name: 'todos_marked_booked')
  final int todosMarkedBooked;

  /// Users with >= 2 trip_created events >= 7 days apart in the window —
  /// the business model's "returned for a second trip" retention signal.
  @JsonKey(name: 'second_trip_retention')
  final int secondTripRetention;

  /// Users with plan sessions on >= 2 distinct days (session frequency,
  /// NOT trip retention — formerly `returning_users`).
  @JsonKey(name: 'session_frequency_returning')
  final int sessionFrequencyReturning;

  /// MAU: distinct signed-in users with >= 1 plan session in the window.
  @JsonKey(name: 'active_users')
  final int activeUsers;
  @JsonKey(name: 'plan_sessions')
  final int planSessions;
  @JsonKey(name: 'plan_sessions_anonymous')
  final int planSessionsAnonymous;

  /// Sessions whose agent loop hit the max-iterations safety cap (a
  /// runaway-loop signal — formerly `plan_cap_hits`).
  @JsonKey(name: 'agent_loop_cap_hits')
  final int agentLoopCapHits;
  @JsonKey(name: 'plan_input_tokens')
  final int planInputTokens;
  @JsonKey(name: 'plan_output_tokens')
  final int planOutputTokens;
  @JsonKey(name: 'plan_cache_read_tokens')
  final int planCacheReadTokens;
  @JsonKey(name: 'plan_cache_creation_tokens')
  final int planCacheCreationTokens;

  /// Estimated Claude spend for the window in USD (Claude only — Places
  /// calls are not counted).
  @JsonKey(name: 'est_claude_cost_usd')
  final double estClaudeCostUsd;

  /// estClaudeCostUsd / activeUsers — the §8 COGS-per-active-user estimate.
  @JsonKey(name: 'est_cogs_per_active_user')
  final double estCogsPerActiveUser;

  /// Free-cap would-hit crossings per cap kind (plan_runs / active_trips) —
  /// the Phase-3 demand signal. Measurement only; nothing is enforced.
  @JsonKey(name: 'free_cap_would_hits')
  final Map<String, int> freeCapWouldHits;

  /// Distinct users who crossed each cap at least once in the window — the
  /// cohort size the paid-tier trigger reads.
  @JsonKey(name: 'free_cap_users_affected')
  final Map<String, int> freeCapUsersAffected;

  /// PROCESS-LIFETIME Google Places call counters + estimated spend, reset on
  /// every API restart/deploy — NOT scoped to the days window like the rest
  /// of this model. Nullable: absent on API builds older than this field.
  @JsonKey(name: 'places_calls_since_process_start')
  final PlacesCalls? placesCallsSinceProcessStart;

  /// PROCESS-LIFETIME Ticketmaster call counters (free tier — quota/cache
  /// visibility, no cost estimate). Nullable: absent on older API builds.
  @JsonKey(name: 'events_calls_since_process_start')
  final UpstreamCallCounts? eventsCallsSinceProcessStart;

  const AdminMetrics({
    this.days = 30,
    this.landingViews,
    this.signups = 0,
    this.activatedSignups = 0,
    this.activationRate = 0,
    this.onboardingsCompleted = 0,
    this.tripsCreated = 0,
    this.tripsRefined = 0,
    this.tripsWithBookingClick = 0,
    this.attachRate = 0,
    this.bookingClicks = 0,
    this.bookingClicksAnonymous,
    this.clicksByProvider = const {},
    this.clicksByProviderAnonymous,
    this.todosMarkedBooked = 0,
    this.secondTripRetention = 0,
    this.sessionFrequencyReturning = 0,
    this.activeUsers = 0,
    this.planSessions = 0,
    this.planSessionsAnonymous = 0,
    this.agentLoopCapHits = 0,
    this.planInputTokens = 0,
    this.planOutputTokens = 0,
    this.planCacheReadTokens = 0,
    this.planCacheCreationTokens = 0,
    this.estClaudeCostUsd = 0,
    this.estCogsPerActiveUser = 0,
    this.freeCapWouldHits = const {},
    this.freeCapUsersAffected = const {},
    this.placesCallsSinceProcessStart,
    this.eventsCallsSinceProcessStart,
  });

  factory AdminMetrics.fromJson(Map<String, dynamic> json) =>
      _$AdminMetricsFromJson(json);
  Map<String, dynamic> toJson() => _$AdminMetricsToJson(this);
}
