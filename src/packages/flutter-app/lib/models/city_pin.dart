import 'package:json_annotation/json_annotation.dart';

part 'city_pin.g.dart';

/// One located hub city on a list-row payload (specs/trips-page-insights):
/// the trips-list lateral emits a pin per hub whose itinerary has a real
/// coordinate — the (0,0) no-location sentinel never reaches the wire, so
/// [lat]/[lng] are non-nullable here. Pins arrive in first-appearance order
/// and are a subset of [Trip.cities].
@JsonSerializable()
class CityPin {
  final String city;
  final double lat;
  final double lng;

  const CityPin({
    required this.city,
    required this.lat,
    required this.lng,
  });

  factory CityPin.fromJson(Map<String, dynamic> json) =>
      _$CityPinFromJson(json);
  Map<String, dynamic> toJson() => _$CityPinToJson(this);
}
