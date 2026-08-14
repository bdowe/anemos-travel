import 'package:json_annotation/json_annotation.dart';

part 'expense.g.dart';

/// One expense line-item on a trip's budget. [category] is a tag from the
/// backend's bounded set (flights | lodging | food | activities | transport |
/// shopping | general), used only for client-side subtotals — there are no
/// per-category targets. [amount] is assumed to be in the budget's currency.
///
/// [sourceKind]/[sourceId] link an autopopulated expense to the booking row
/// it was created from (booking_todo | accommodation | segment; null for
/// manual entries), and [auto] means the row is a system-managed mirror of
/// that booking's booked state — unbooking removes it. Any user edit of
/// category/label/amount flips auto false server-side (manual takeover), and
/// unbooking then leaves the row (migration 00061's contract).
@JsonSerializable()
class Expense {
  final String id;
  final String category;
  final String label;
  final double amount;
  final int position;
  final bool auto;
  @JsonKey(name: 'source_kind')
  final String? sourceKind;
  @JsonKey(name: 'source_id')
  final String? sourceId;

  const Expense({
    required this.id,
    required this.category,
    required this.label,
    required this.amount,
    this.position = 0,
    this.auto = false,
    this.sourceKind,
    this.sourceId,
  });

  Expense copyWith({String? category, String? label, double? amount}) => Expense(
        id: id,
        category: category ?? this.category,
        label: label ?? this.label,
        amount: amount ?? this.amount,
        position: position,
        auto: auto,
        sourceKind: sourceKind,
        sourceId: sourceId,
      );

  factory Expense.fromJson(Map<String, dynamic> json) =>
      _$ExpenseFromJson(json);
  Map<String, dynamic> toJson() => _$ExpenseToJson(this);
}
