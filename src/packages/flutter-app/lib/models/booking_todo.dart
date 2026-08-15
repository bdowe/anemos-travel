import 'package:json_annotation/json_annotation.dart';

part 'booking_todo.g.dart';

@JsonSerializable()
class BookingTodo {
  final String id;
  final String kind; // stay | transport | other
  @JsonKey(name: 'todo_key')
  final String todoKey;
  final String title;
  final String? subtitle;
  final String? provider; // airbnb | google_flights | ...
  @JsonKey(name: 'search_url')
  final String? searchUrl;
  @JsonKey(name: 'depart_date')
  final String? departDate;
  @JsonKey(name: 'return_date')
  final String? returnDate;

  /// Per-leg transport-mode override (flight|car|train|bus|ferry) for
  /// transport rows. Null = derived default; the server preserves it across
  /// syncs like [booked].
  final String? mode;

  /// Which leg of the journey this row is, as the SERVER stores it:
  /// `home_outbound` | `home_return` | `inter_city` | `stay`
  /// (booking_todo_identity.go). Read, never derived here — a home leg the
  /// server demoted to `inter_city` on a key collision would fool any
  /// client-side guess, and only the server knows that happened.
  final String? role;
  final bool booked;
  final bool auto;
  final int position;

  /// True when this row is one of the trip's two journey endpoints — the leg
  /// out and the leg home — and so is titled from the TRIP's airports rather
  /// than from the itinerary's cities.
  bool get isHomeLeg => role == 'home_outbound' || role == 'home_return';

  const BookingTodo({
    required this.id,
    required this.kind,
    required this.todoKey,
    required this.title,
    this.subtitle,
    this.provider,
    this.searchUrl,
    this.departDate,
    this.returnDate,
    this.mode,
    this.role,
    this.booked = false,
    this.auto = true,
    this.position = 0,
  });

  BookingTodo copyWith({bool? booked}) => BookingTodo(
        id: id,
        kind: kind,
        todoKey: todoKey,
        title: title,
        subtitle: subtitle,
        provider: provider,
        searchUrl: searchUrl,
        departDate: departDate,
        returnDate: returnDate,
        mode: mode,
        role: role,
        booked: booked ?? this.booked,
        auto: auto,
        position: position,
      );

  factory BookingTodo.fromJson(Map<String, dynamic> json) =>
      _$BookingTodoFromJson(json);
  Map<String, dynamic> toJson() => _$BookingTodoToJson(this);
}
