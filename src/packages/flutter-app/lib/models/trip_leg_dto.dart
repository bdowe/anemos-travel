import 'package:json_annotation/json_annotation.dart';

part 'trip_leg_dto.g.dart';

/// One server-computed city leg (specs/server-leg-dates): the rendered date
/// span per contiguous city run, from the API's one derivation
/// (computeTripLegs, trip_render_legs.go). Present on full trip views only;
/// clients render these when available and fall back to the local
/// utils/leg_ranges.dart derivation when absent (offline caches, old
/// snapshots, rollback).
@JsonSerializable(explicitToJson: true)
class TripLegDto {
  /// Per-run key — revisited cities get "City#2", "City#3", … suffixes,
  /// matching the client tripLegs convention for collapse/header registries.
  final String key;

  /// Display label; 'Other places' sentinel for hubless runs (localized at
  /// render time, never here).
  final String label;

  /// Raw hub locality; null for hubless runs.
  final String? hub;

  /// Rendered span, YYYY-MM-DD, arrival → departure (checkout-day
  /// semantics). Null when the leg has no calendar span.
  @JsonKey(name: 'start_date')
  final String? startDate;
  @JsonKey(name: 'end_date')
  final String? endDate;

  /// Which rule produced the span: 'stay' | 'items' | 'auto' | null.
  @JsonKey(name: 'date_source')
  final String? dateSource;

  /// True when a squeeze collapsed the leg to a zero-night stop at its
  /// arrival (the interim state chat narrates as "no nights left").
  @JsonKey(name: 'zero_night')
  final bool? zeroNight;

  /// The leg's contiguous item-position bounds within the itinerary.
  @JsonKey(name: 'first_position')
  final int firstPosition;
  @JsonKey(name: 'last_position')
  final int lastPosition;

  /// Representative coordinate (first geocoded item); null when ungeocoded.
  final double? lat;
  final double? lng;

  const TripLegDto({
    required this.key,
    required this.label,
    this.hub,
    this.startDate,
    this.endDate,
    this.dateSource,
    this.zeroNight,
    required this.firstPosition,
    required this.lastPosition,
    this.lat,
    this.lng,
  });

  factory TripLegDto.fromJson(Map<String, dynamic> json) =>
      _$TripLegDtoFromJson(json);
  Map<String, dynamic> toJson() => _$TripLegDtoToJson(this);
}
