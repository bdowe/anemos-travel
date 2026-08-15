import 'package:json_annotation/json_annotation.dart';
import 'flight_offer.dart';

part 'flight_search_response.g.dart';

@JsonSerializable(explicitToJson: true)
class FlightSearchResponse {
  @JsonKey(defaultValue: <FlightOffer>[])
  final List<FlightOffer> offers;
  @JsonKey(name: 'best_offer_id')
  final String? bestOfferId;
  @JsonKey(name: 'optimize_for')
  final String optimizeFor;

  /// The bag tier these results were actually priced for — the RESOLVED value,
  /// which may differ from what was sent.
  @JsonKey(defaultValue: 'carry_on')
  final String baggage;

  /// Stable code (never prose) for a bag fee the provider could not include,
  /// localized on this side. Null when the prices cover what was asked for.
  @JsonKey(name: 'baggage_note')
  final String? baggageNote;
  final int count;
  final String status;

  const FlightSearchResponse({
    required this.offers,
    this.bestOfferId,
    required this.optimizeFor,
    this.baggage = 'carry_on',
    this.baggageNote,
    required this.count,
    required this.status,
  });

  factory FlightSearchResponse.fromJson(Map<String, dynamic> json) =>
      _$FlightSearchResponseFromJson(json);
  Map<String, dynamic> toJson() => _$FlightSearchResponseToJson(this);
}
