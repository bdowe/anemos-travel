import 'package:json_annotation/json_annotation.dart';

part 'daily_spend.g.dart';

/// The suggested per-person daily food & drink spend for each city on a trip
/// (specs/daily-spend-guide), from `GET /trips/{id}/budget/daily-spend`.
///
/// [basis] names where the money came from and is the reason this is safe to
/// show: it is an **estimate**, never a looked-up price, and the section says
/// so on screen. There is no free global meal-price feed to look one up in —
/// see daily_spend_service.go for the full argument.
///
/// [tier] is the RESOLVED spending level and [tierSource] says what resolved it
/// (`request` | `profile` | `default`). Both ride the wire rather than being
/// re-derived here, so the card can credit a saved preference truthfully
/// instead of implying one the traveler never set.
///
/// [unavailableReason] is a stable code (`not_configured` | `provider_error` |
/// `no_cities`) set exactly when [cities] is empty. The endpoint never errors —
/// a suggestion that cannot be produced is not the traveler's problem — so the
/// section simply does not render.
@JsonSerializable(explicitToJson: true)
class DailySpendGuide {
  final String currency;
  final String tier;
  @JsonKey(name: 'tier_source')
  final String tierSource;
  final String basis;
  final List<DailySpendCity> cities;
  @JsonKey(name: 'unavailable_reason')
  final String? unavailableReason;

  const DailySpendGuide({
    this.currency = 'USD',
    this.tier = 'mid',
    this.tierSource = 'default',
    this.basis = 'estimate',
    this.cities = const [],
    this.unavailableReason,
  });

  /// Nothing to show. Kept as a named property rather than `cities.isEmpty` at
  /// each call site so "should this section exist" has one answer.
  bool get isEmpty => cities.isEmpty;

  factory DailySpendGuide.fromJson(Map<String, dynamic> json) =>
      _$DailySpendGuideFromJson(json);
  Map<String, dynamic> toJson() => _$DailySpendGuideToJson(this);
}

/// One city leg's suggestion.
@JsonSerializable()
class DailySpendCity {
  /// The server's `RenderLeg.Key` — the identity an accepted plan is stored
  /// under (`Expense.legKey`). The card finds its own line with this rather
  /// than by matching the label it generated itself.
  @JsonKey(name: 'leg_key')
  final String legKey;
  final String label;

  /// NIGHTS, not days. Two legs share their transition day (Rome ends the
  /// morning Florence begins), so counting days would bill that day twice and
  /// the section could never reconcile with the trip's own length. Comes from
  /// the same derivation as the nights on the city header chip.
  final int nights;

  /// Per person, per day, in [DailySpendGuide.currency]. Party size is applied
  /// client-side — it is the only thing the server does not know.
  @JsonKey(name: 'daily_amount')
  final double dailyAmount;

  /// One short phrase naming the meals the amount covers.
  final String includes;

  const DailySpendCity({
    required this.legKey,
    required this.label,
    required this.nights,
    required this.dailyAmount,
    this.includes = '',
  });

  factory DailySpendCity.fromJson(Map<String, dynamic> json) =>
      _$DailySpendCityFromJson(json);
  Map<String, dynamic> toJson() => _$DailySpendCityToJson(this);
}
