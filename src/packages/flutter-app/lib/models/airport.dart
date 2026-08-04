import 'package:json_annotation/json_annotation.dart';

part 'airport.g.dart';

@JsonSerializable()
class Airport {
  @JsonKey(name: 'iata_code')
  final String iataCode;
  final String name;
  final String city;
  final String country;
  @JsonKey(name: 'sub_type')
  final String subType;

  /// Null when Duffel returned no coordinates for this place (some city-type
  /// entries) or for placeholder instances built from a bare IATA code.
  final double? latitude;
  final double? longitude;

  const Airport({
    required this.iataCode,
    required this.name,
    this.city = '',
    this.country = '',
    this.subType = '',
    this.latitude,
    this.longitude,
  });

  /// "Paris (CDG)" style label for autocomplete rows and field display. Falls
  /// back to the bare code when no place name is known (e.g. a placeholder built
  /// from just a saved IATA code).
  String get label {
    final place = city.isNotEmpty ? city : name;
    if (place.isEmpty || place == iataCode) return iataCode;
    return '$place ($iataCode)';
  }

  factory Airport.fromJson(Map<String, dynamic> json) => _$AirportFromJson(json);
  Map<String, dynamic> toJson() => _$AirportToJson(this);
}
