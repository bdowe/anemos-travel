import 'package:json_annotation/json_annotation.dart';

part 'budget.g.dart';

/// The single per-trip budget: one [targetAmount] target in one [currency]
/// (default USD — there is no trip-level currency to inherit) plus
/// server-derived totals. All expenses are assumed to be in [currency] — there
/// is no cross-currency summing or FX.
///
/// [spent] and [remaining] keep the meaning they have always had — money
/// actually spent, and target minus that. The planned-vs-paid split (migration
/// 00067) added three more, all computed in one place on the server:
///
///  * [planned] — the sum of every stated plan. It does NOT shrink as lines are
///    paid; that is the point, since at the end of a trip everything is bought.
///    Money spent that was never planned contributes nothing here, so it shows
///    up as a gap against [spent] rather than being absorbed.
///  * [projected] — `actual ?? planned` summed: what the trip costs if every
///    unpaid line lands at its plan.
///  * [planVariance] — how the PAID lines came in against their own plans
///    (positive = over), scoped to lines carrying both numbers. Null means
///    nothing to compare yet, which is not the same as zero.
///
/// The three new totals are nullable **on this side only**: a client that
/// outruns the server, or a bundle cached before the split shipped, must render
/// the old Budget tab rather than throw. Null means "unknown", never 0.
@JsonSerializable()
class Budget {
  @JsonKey(name: 'target_amount')
  final double? targetAmount;
  final String currency;
  final double spent;
  final double? remaining;
  final double? planned;
  final double? projected;
  @JsonKey(name: 'plan_variance')
  final double? planVariance;

  const Budget({
    this.targetAmount,
    this.currency = 'USD',
    this.spent = 0,
    this.remaining,
    this.planned,
    this.projected,
    this.planVariance,
  });

  factory Budget.fromJson(Map<String, dynamic> json) => _$BudgetFromJson(json);
  Map<String, dynamic> toJson() => _$BudgetToJson(this);
}
