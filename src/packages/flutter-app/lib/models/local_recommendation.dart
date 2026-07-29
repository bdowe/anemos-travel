import 'package:json_annotation/json_annotation.dart';

part 'local_recommendation.g.dart';

/// A hand-curated, locally-sourced recommendation returned by
/// /local/recommendations, matching the Go API's LocalRec type. Carries both the
/// place and the attribution of the local who vouched for it.
@JsonSerializable()
class LocalRecommendation {
  final String id;
  final String name;
  @JsonKey(defaultValue: '')
  final String city;
  @JsonKey(defaultValue: '')
  final String neighborhood;
  @JsonKey(defaultValue: '')
  final String category;
  @JsonKey(defaultValue: '')
  final String address;
  @JsonKey(name: 'place_id', defaultValue: '')
  final String placeId;
  final double? latitude;
  final double? longitude;
  @JsonKey(defaultValue: '')
  final String tip;
  @JsonKey(defaultValue: '')
  final String quote;
  @JsonKey(defaultValue: <String>[])
  final List<String> tags;
  @JsonKey(name: 'source_name', defaultValue: '')
  final String sourceName;
  @JsonKey(name: 'source_bio', defaultValue: '')
  final String sourceBio;
  @JsonKey(name: 'source_photo_url', defaultValue: '')
  final String sourcePhotoUrl;
  @JsonKey(name: 'source_expertise', defaultValue: '')
  final String sourceExpertise;
  @JsonKey(name: 'source_credibility', defaultValue: '')
  final String sourceCredibility;

  /// The VENUE's Google photo (agent-enriched on the /plan path only) —
  /// distinct from [sourcePhotoUrl], the human recommender's headshot.
  @JsonKey(name: 'photo_ref', defaultValue: '')
  final String photoRef;
  @JsonKey(name: 'photo_attribution', defaultValue: '')
  final String photoAttribution;

  const LocalRecommendation({
    required this.id,
    required this.name,
    this.city = '',
    this.neighborhood = '',
    this.category = '',
    this.address = '',
    this.placeId = '',
    this.latitude,
    this.longitude,
    this.tip = '',
    this.quote = '',
    this.tags = const [],
    this.sourceName = '',
    this.sourceBio = '',
    this.sourcePhotoUrl = '',
    this.sourceExpertise = '',
    this.sourceCredibility = '',
    this.photoRef = '',
    this.photoAttribution = '',
  });

  /// "Ana · Lisbon chef, 20yr resident" style credit line for the card.
  String get creditLine => [
        if (sourceName.isNotEmpty) sourceName,
        if (sourceCredibility.isNotEmpty) sourceCredibility,
      ].join(' · ');

  factory LocalRecommendation.fromJson(Map<String, dynamic> json) =>
      _$LocalRecommendationFromJson(json);
  Map<String, dynamic> toJson() => _$LocalRecommendationToJson(this);
}
