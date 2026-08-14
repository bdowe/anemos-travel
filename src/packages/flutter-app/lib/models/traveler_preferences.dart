import 'package:json_annotation/json_annotation.dart';

part 'traveler_preferences.g.dart';

@JsonSerializable()
class TravelerPreferences {
  final String? budget;
  final String? pace;
  final List<String> interests;
  @JsonKey(name: 'home_airport')
  final String? homeAirport;
  @JsonKey(name: 'profile_notes')
  final String? profileNotes;
  @JsonKey(name: 'work_style')
  final String? workStyle;

  const TravelerPreferences({
    this.budget,
    this.pace,
    this.interests = const [],
    this.homeAirport,
    this.profileNotes,
    this.workStyle,
  });

  factory TravelerPreferences.fromJson(Map<String, dynamic> json) =>
      _$TravelerPreferencesFromJson(json);
  Map<String, dynamic> toJson() => _$TravelerPreferencesToJson(this);
}
