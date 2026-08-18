import 'package:json_annotation/json_annotation.dart';

part 'expense.g.dart';

/// One expense line-item on a trip's budget. [category] is a tag from the
/// backend's bounded set (flights | lodging | food | activities | transport |
/// shopping | general), used only for client-side subtotals — there are no
/// per-category targets. Amounts are assumed to be in the budget's currency.
///
/// A line carries up to TWO numbers (migration 00067): [plannedAmount], what
/// the traveler meant to spend, and [actualAmount], what it cost. At least one
/// is always present, and [purchased] is the server's statement of which — a
/// line is paid exactly when it has an amount paid. The plan SURVIVES the
/// purchase (there is no API that clears it), which is what lets the Budget tab
/// still answer "what did I plan vs what did I spend" after a finished trip.
///
/// [amount] is the legacy headline figure — `actual ?? planned`, maintained by
/// the database — kept non-nullable so a cached bundle can never crash on it.
/// Prefer [plannedFor] / [paidAmount]; [amount] exists for the one-number
/// surfaces that predate the split.
///
/// [sourceKind]/[sourceId] link an autopopulated expense to the booking row
/// it was created from (booking_todo | accommodation | segment; null for
/// manual entries), and [auto] means the row is a system-managed mirror of
/// that booking's booked state. Ownership of a linked row is SPLIT: the system
/// owns the payment (unbooking clears it), the traveler owns the plan
/// (unbooking keeps it). Any user edit of category/label/amount flips auto
/// false server-side (manual takeover); stating a plan does not.
@JsonSerializable()
class Expense {
  final String id;
  final String category;
  final String label;
  final double amount;
  @JsonKey(name: 'planned_amount')
  final double? plannedAmount;
  @JsonKey(name: 'actual_amount')
  final double? actualAmount;
  final bool purchased;
  final int position;
  final bool auto;
  @JsonKey(name: 'source_kind')
  final String? sourceKind;
  @JsonKey(name: 'source_id')
  final String? sourceId;

  /// The city leg this money belongs to (migration 00070, generalized by
  /// 00072), or null when the line isn't filed under a city. The Budget tab's
  /// spend-per-city grouping key. Deliberately NOT part of the `auto`
  /// contract above: where a line is filed is the traveler's organization, so
  /// no booking-state change touches it.
  @JsonKey(name: 'leg_key')
  final String? legKey;

  /// True on the one row that IS this city's per-day plan slot for its
  /// category (00072) — the identity the daily food & drink card finds its
  /// own line by. NEVER infer plan-ness from `legKey != null`: since 00072
  /// any line can carry a city. Defaults false so a cached pre-00072 payload
  /// reads as "not a plan slot", the safe meaning.
  @JsonKey(name: 'leg_plan')
  final bool legPlan;

  const Expense({
    required this.id,
    required this.category,
    required this.label,
    required this.amount,
    this.plannedAmount,
    this.actualAmount,
    this.purchased = true,
    this.position = 0,
    this.auto = false,
    this.sourceKind,
    this.sourceId,
    this.legKey,
    this.legPlan = false,
  });

  /// What this line was planned at, or null if it never carried a plan.
  double? get plannedFor => plannedAmount;

  /// What this line actually cost, or null while it is only planned.
  ///
  /// Falls back to [amount] for a payload that predates the split (an old
  /// server, or a response cached before it shipped): those amounts were
  /// already counted as spend, so reading them as paid is the honest legacy
  /// meaning.
  double? get paidAmount {
    if (actualAmount != null) return actualAmount;
    if (plannedAmount == null && purchased) return amount;
    return null;
  }

  /// True when the line shows two different numbers ("planned $400 → paid
  /// $372"). Equal amounts collapse to one — "$750 → $750" is noise.
  bool get showsPair =>
      plannedFor != null && paidAmount != null && plannedFor != paidAmount;

  Expense copyWith({
    String? category,
    String? label,
    double? amount,
    double? plannedAmount,
    double? actualAmount,
    bool? purchased,
    bool clearPlanned = false,
    bool clearActual = false,
  }) =>
      Expense(
        id: id,
        category: category ?? this.category,
        label: label ?? this.label,
        amount: amount ?? this.amount,
        plannedAmount: clearPlanned ? null : (plannedAmount ?? this.plannedAmount),
        actualAmount: clearActual ? null : (actualAmount ?? this.actualAmount),
        purchased: purchased ?? this.purchased,
        position: position,
        auto: auto,
        sourceKind: sourceKind,
        sourceId: sourceId,
        legKey: legKey,
        legPlan: legPlan,
      );

  factory Expense.fromJson(Map<String, dynamic> json) =>
      _$ExpenseFromJson(json);
  Map<String, dynamic> toJson() => _$ExpenseToJson(this);
}
