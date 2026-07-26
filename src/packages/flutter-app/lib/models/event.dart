import 'package:json_annotation/json_annotation.dart';

part 'event.g.dart';

/// A local event (concert, sport, festival, show) returned by /events/search,
/// matching the Go API's Event type.
@JsonSerializable()
class Event {
  final String id;
  final String name;
  @JsonKey(defaultValue: '')
  final String category;
  @JsonKey(defaultValue: '')
  final String venue;
  @JsonKey(defaultValue: '')
  final String city;
  @JsonKey(name: 'start_date', defaultValue: '')
  final String startDate;
  @JsonKey(name: 'start_time', defaultValue: '')
  final String startTime;
  @JsonKey(defaultValue: 0)
  final double latitude;
  @JsonKey(defaultValue: 0)
  final double longitude;
  @JsonKey(defaultValue: '')
  final String url;
  @JsonKey(name: 'image_url', defaultValue: '')
  final String imageUrl;

  const Event({
    required this.id,
    required this.name,
    this.category = '',
    this.venue = '',
    this.city = '',
    this.startDate = '',
    this.startTime = '',
    this.latitude = 0,
    this.longitude = 0,
    this.url = '',
    this.imageUrl = '',
  });

  // Display labels live with the presentation layer (eventWhenLabel in
  // event_card.dart) so dates localize via intl instead of hand-rolled
  // English arrays; the model stays a pure JSON mirror.

  factory Event.fromJson(Map<String, dynamic> json) => _$EventFromJson(json);
  Map<String, dynamic> toJson() => _$EventToJson(this);
}
