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
  final bool booked;
  final bool auto;
  final int position;

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
        booked: booked ?? this.booked,
        auto: auto,
        position: position,
      );

  factory BookingTodo.fromJson(Map<String, dynamic> json) =>
      _$BookingTodoFromJson(json);
  Map<String, dynamic> toJson() => _$BookingTodoToJson(this);
}
