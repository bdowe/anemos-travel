import 'package:json_annotation/json_annotation.dart';
import 'itinerary_item.dart';
import 'accommodation.dart';
import 'trip_segment.dart';
import 'booking_todo.dart';
import 'city_pin.dart';
import 'trip_leg_dto.dart';

part 'trip.g.dart';

@JsonSerializable(explicitToJson: true)
class Trip {
  final String id;
  final String title;
  final String? summary;
  @JsonKey(name: 'start_date')
  final String? startDate;
  @JsonKey(name: 'end_date')
  final String? endDate;
  @JsonKey(name: 'chat_id')
  final String? chatId;

  /// How the traveler moves between cities on this trip: 'flight', 'car',
  /// 'train', 'bus', 'ferry', or 'mixed'. Null = never stated ⇒ the legacy
  /// flight-default behavior in drafts, todos, and Trip Health.
  @JsonKey(name: 'travel_mode')
  final String? travelMode;
  @JsonKey(name: 'version_count')
  final int? versionCount;
  final List<String>? cities;
  @JsonKey(name: 'created_at')
  final String createdAt;
  @JsonKey(name: 'updated_at')
  final String updatedAt;
  final List<ItineraryItem>? items;
  final List<Accommodation>? accommodations;
  final List<TripSegment>? segments;
  @JsonKey(name: 'booking_todos')
  final List<BookingTodo>? bookingTodos;

  /// 'owner' or 'editor' (collaborator). Missing on older responses ⇒ owner.
  final String? access;

  /// The owner's display name, set when access == 'editor'.
  @JsonKey(name: 'owner_name')
  final String? ownerName;

  /// Who last edited the trip's content — omitted for the caller's own edits
  /// (specs/shared-trip-freshness).
  @JsonKey(name: 'updated_by_name')
  final String? updatedByName;

  /// True on an owner's trip that has active co-planners: the detail screen
  /// polls for freshness. Editors poll based on [access] alone. Also set on
  /// list rows (the shared-out pill on trip cards).
  final bool? shared;

  /// List-row enrichment (GET /trips laterals): total itinerary items and
  /// booking-todo progress. Null on full views, old servers, and stale
  /// offline snapshots — cards hide the chips rather than derive locally
  /// (the server row is the one derivation for list display, like [cities]).
  /// Booking fields are absent for viewer-role shared trips.
  @JsonKey(name: 'item_count')
  final int? itemCount;
  @JsonKey(name: 'booking_total')
  final int? bookingTotal;
  @JsonKey(name: 'booking_booked')
  final int? bookingBooked;

  /// List-row insight enrichment (specs/trips-page-insights), same null
  /// contract as [itemCount]: null = full view / old server / stale offline
  /// snapshot / shared row — cards hide the chips rather than derive locally.
  /// Present values carry explicit zeros ("0/2 stays" is real data).
  @JsonKey(name: 'stay_total')
  final int? stayTotal;
  @JsonKey(name: 'stay_booked')
  final int? stayBooked;
  @JsonKey(name: 'packing_total')
  final int? packingTotal;
  @JsonKey(name: 'packing_done')
  final int? packingDone;

  /// Budget insight: [budgetTarget] null = no target set; [budgetSpent]
  /// null = not a list row, 0 = nothing spent. Single-currency by design
  /// (the buildBudgetResponse rule).
  @JsonKey(name: 'budget_target')
  final double? budgetTarget;
  @JsonKey(name: 'budget_spent')
  final double? budgetSpent;
  @JsonKey(name: 'budget_currency')
  final String? budgetCurrency;

  /// Earliest unbooked FUTURE transport departure (YYYY-MM-DD) — the booking
  /// urgency nudge's fact. Null when none (or any of the null cases above);
  /// the client re-guards the display window against device-local today.
  @JsonKey(name: 'next_transport_depart')
  final String? nextTransportDepart;

  /// Located hub cities in first-appearance order — a subset of [cities]
  /// (hubs with only sentinel (0,0) items are omitted). Feeds the travel
  /// footprint map straight from the list payload.
  @JsonKey(name: 'city_pins')
  final List<CityPin>? cityPins;

  /// Server-computed city legs (specs/server-leg-dates) — present on full
  /// trip views; absent on list responses, offline caches, and old
  /// snapshots, where clients fall back to the local derivation.
  final List<TripLegDto>? legs;

  const Trip({
    required this.id,
    required this.title,
    this.summary,
    this.startDate,
    this.endDate,
    this.chatId,
    this.travelMode,
    this.versionCount,
    this.cities,
    required this.createdAt,
    required this.updatedAt,
    this.items,
    this.accommodations,
    this.segments,
    this.bookingTodos,
    this.access,
    this.ownerName,
    this.updatedByName,
    this.shared,
    this.itemCount,
    this.bookingTotal,
    this.bookingBooked,
    this.stayTotal,
    this.stayBooked,
    this.packingTotal,
    this.packingDone,
    this.budgetTarget,
    this.budgetSpent,
    this.budgetCurrency,
    this.nextTransportDepart,
    this.cityPins,
    this.legs,
  });

  /// True when the current user may edit this trip: owner or editor
  /// co-planner. Viewer-role members (future) are read-only.
  bool get canEdit => access == null || access == 'owner' || access == 'editor';

  /// True when the current user owns this trip (missing access ⇒ owner,
  /// for responses that predate collaboration).
  bool get isOwner => access == null || access == 'owner';

  factory Trip.fromJson(Map<String, dynamic> json) => _$TripFromJson(json);
  Map<String, dynamic> toJson() => _$TripToJson(this);
}
