import 'package:json_annotation/json_annotation.dart';

part 'trip_finding.g.dart';

/// One issue surfaced by the trip-health review (`GET /trips/{id}/review`).
/// [severity] is info | warn | critical; [category] is one of dates |
/// unscheduled | packing | lodging | transit | budget | bookings. [day] and
/// [itemId] are optional deep-link anchors: when present, tapping the finding
/// scrolls the itinerary to that day (or the day of that item).
@JsonSerializable()
class TripFinding {
  final String severity;
  final String category;
  final String message;
  @JsonKey(name: 'trip_id')
  final String tripId;
  final int? day;
  @JsonKey(name: 'item_id')
  final String? itemId;

  /// Optional one-tap fix descriptor (added in the review's PR1). Null/omitted
  /// when a finding has no actionable fix.
  @JsonKey(name: 'fix')
  final FindingFix? fix;

  const TripFinding({
    required this.severity,
    required this.category,
    required this.message,
    required this.tripId,
    this.day,
    this.itemId,
    this.fix,
  });

  factory TripFinding.fromJson(Map<String, dynamic> json) =>
      _$TripFindingFromJson(json);
  Map<String, dynamic> toJson() => _$TripFindingToJson(this);
}

/// A structured "fix" for a [TripFinding]: what one-tap action resolves it plus
/// any prefill hints. [action] is one of add_lodging | add_transport |
/// move_item | mark_booked | add_packing | set_dates | raise_budget; [label] is
/// the human button text. Every other field is optional and only present for
/// the action(s) that use it.
@JsonSerializable()
class FindingFix {
  final String action;
  final String label;

  @JsonKey(name: 'item_id')
  final String? itemId;

  /// For mark_booked: accommodation | segment.
  @JsonKey(name: 'entity_type')
  final String? entityType;

  /// For move_item: the day to move the item to.
  @JsonKey(name: 'target_day')
  final int? targetDay;

  /// For add_lodging: the city the stay is for.
  final String? city;

  /// For add_transport: leg endpoints.
  final String? origin;
  final String? destination;

  /// For add_lodging: YYYY-MM-DD check-in / check-out.
  @JsonKey(name: 'check_in')
  final String? checkIn;
  @JsonKey(name: 'check_out')
  final String? checkOut;

  /// For add_transport: YYYY-MM-DD departure date.
  final String? date;

  /// For add_transport: e.g. ferry, flight, train.
  final String? mode;

  /// For add_packing: the item + its category.
  @JsonKey(name: 'packing_item')
  final String? packingItem;
  @JsonKey(name: 'packing_category')
  final String? packingCategory;

  const FindingFix({
    required this.action,
    required this.label,
    this.itemId,
    this.entityType,
    this.targetDay,
    this.city,
    this.origin,
    this.destination,
    this.checkIn,
    this.checkOut,
    this.date,
    this.mode,
    this.packingItem,
    this.packingCategory,
  });

  factory FindingFix.fromJson(Map<String, dynamic> json) =>
      _$FindingFixFromJson(json);
  Map<String, dynamic> toJson() => _$FindingFixToJson(this);
}

/// The full `GET /trips/{id}/review` payload: the ordered findings plus the
/// Next Step CTA projection (specs/next-step-cta). [nextStep]/[planProgress]
/// are omitted by the server for past trips — absence means "nothing left to
/// plan", which is distinct from the all_set terminal step.
@JsonSerializable()
class TripReview {
  final List<TripFinding> findings;
  @JsonKey(name: 'next_step')
  final NextStep? nextStep;
  @JsonKey(name: 'plan_progress')
  final PlanProgress? planProgress;

  const TripReview({
    required this.findings,
    this.nextStep,
    this.planProgress,
  });

  factory TripReview.fromJson(Map<String, dynamic> json) =>
      _$TripReviewFromJson(json);
  Map<String, dynamic> toJson() => _$TripReviewToJson(this);
}

/// The first unmet phase of the planning ladder (server-derived, one per
/// trip). [kind] is one of set_dates | plan_itinerary | add_lodging |
/// add_transport | schedule_items | book_trip | add_packing | all_set; treat
/// unknown kinds as future ladder phases (fall back to [fix] or the health
/// sheet). [title]/[detail] arrive localized. [seedPrompt] is the canonical-
/// English chat seed for chat-driven steps — send it verbatim, never a
/// localized variant (specs/i18n-spanish).
@JsonSerializable()
class NextStep {
  final String kind;
  final String title;
  final String? detail;
  final int? day;
  final int? count;

  /// Same contract as a finding's fix — reuses the screen's apply-fix
  /// plumbing for mechanical steps.
  final FindingFix? fix;

  @JsonKey(name: 'seed_prompt')
  final String? seedPrompt;

  const NextStep({
    required this.kind,
    required this.title,
    this.detail,
    this.day,
    this.count,
    this.fix,
    this.seedPrompt,
  });

  factory NextStep.fromJson(Map<String, dynamic> json) =>
      _$NextStepFromJson(json);
  Map<String, dynamic> toJson() => _$NextStepToJson(this);
}

/// Prefix progress through the planning ladder: [done] phases are complete
/// from the top, so the current step is phase done+1 of [total]. The total is
/// server-owned so the ladder can grow without a client release.
@JsonSerializable()
class PlanProgress {
  final int done;
  final int total;

  const PlanProgress({required this.done, required this.total});

  factory PlanProgress.fromJson(Map<String, dynamic> json) =>
      _$PlanProgressFromJson(json);
  Map<String, dynamic> toJson() => _$PlanProgressToJson(this);
}
