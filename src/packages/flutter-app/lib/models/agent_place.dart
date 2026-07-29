import 'package:json_annotation/json_annotation.dart';

part 'agent_place.g.dart';

/// One photo card in the /plan stream's `places` SSE event — a Google Places
/// result the agent surfaced as a recommendation, matching the Go API's
/// placeCard wire struct. Distinct from PlaceSearchResult (different wire
/// keys: scalar `category`, `address`, plus the photo fields).
@JsonSerializable()
class AgentPlace {
  final String name;
  @JsonKey(name: 'place_id', defaultValue: '')
  final String placeId;
  @JsonKey(defaultValue: '')
  final String address;
  @JsonKey(defaultValue: 0)
  final double lat;
  @JsonKey(defaultValue: 0)
  final double lng;
  final double? rating;
  @JsonKey(name: 'price_level')
  final int? priceLevel;
  @JsonKey(defaultValue: '')
  final String category;

  /// Opaque Google photo_reference; the image loads through the API's
  /// /places/photo redirect endpoint (see placePhotoUrl in utils/place_links).
  @JsonKey(name: 'photo_ref', defaultValue: '')
  final String photoRef;

  /// Photographer credit (Google TOS requires showing it), HTML pre-stripped
  /// server-side.
  @JsonKey(name: 'photo_attribution', defaultValue: '')
  final String photoAttribution;

  const AgentPlace({
    required this.name,
    this.placeId = '',
    this.address = '',
    this.lat = 0,
    this.lng = 0,
    this.rating,
    this.priceLevel,
    this.category = '',
    this.photoRef = '',
    this.photoAttribution = '',
  });

  factory AgentPlace.fromJson(Map<String, dynamic> json) =>
      _$AgentPlaceFromJson(json);
  Map<String, dynamic> toJson() => _$AgentPlaceToJson(this);
}
