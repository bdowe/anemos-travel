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

  /// `gym` | `running` | `both` | `none` — the training kept while away.
  /// A constraint on where they sleep and how the day opens, not a taste;
  /// tastes (yoga, climbing) are [interests]. `none` is an answer, not an
  /// absence: it means stop planning around it.
  @JsonKey(name: 'fitness_routine')
  final String? fitnessRoutine;

  /// `easy` | `moderate` | `challenging` — how demanding an active outing
  /// should be. Orthogonal to [pace], which is how many things happen in a day.
  @JsonKey(name: 'outdoor_intensity')
  final String? outdoorIntensity;

  /// `solo` | `partner` | `friends` | `family_with_kids` | `varies`.
  final String? companions;

  /// `personal_item` | `carry_on` | `checked` — the biggest bag this traveler
  /// normally flies with. It is the default every flight search is priced for,
  /// so fares include the bag fees they will actually pay. Null means never
  /// said, which prices a cabin bag rather than assuming they carry nothing.
  final String? baggage;

  const TravelerPreferences({
    this.budget,
    this.pace,
    this.interests = const [],
    this.homeAirport,
    this.profileNotes,
    this.workStyle,
    this.fitnessRoutine,
    this.outdoorIntensity,
    this.companions,
    this.baggage,
  });

  factory TravelerPreferences.fromJson(Map<String, dynamic> json) =>
      _$TravelerPreferencesFromJson(json);
  Map<String, dynamic> toJson() => _$TravelerPreferencesToJson(this);
}
