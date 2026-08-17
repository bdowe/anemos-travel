// daily_spend.dart — the one multiplication behind the daily food & drink
// suggestion (specs/daily-spend-guide).
//
// The server states a per-person, per-day amount and the leg's nights; party
// size is the only factor it cannot know, so the total is composed here. It
// lives in its own function because TWO call sites need the identical number —
// the figure on the card and the `planned_amount` the "Add to plan" button
// posts — and a card that shows one number while filing another is exactly the
// drift docs/zen.md is about.

/// The canonical expense category a daily food & drink plan files under. A
/// value from `kExpenseCategories`, never a localized label.
const String kDailySpendCategory = 'food';

/// Bounds the travelers stepper. Not a business rule — just a sane ceiling for
/// a control that has to stay one tap wide.
const int kDailySpendMinTravelers = 1;
const int kDailySpendMaxTravelers = 12;

/// What a city's food & drink comes to: the per-person daily rate across the
/// leg's nights, for everyone travelling.
double dailySpendTotal({
  required double dailyAmount,
  required int nights,
  required int travelers,
}) =>
    dailyAmount * nights * travelers;

/// Keeps a travelers count inside the stepper's range.
int clampTravelers(int value) => value < kDailySpendMinTravelers
    ? kDailySpendMinTravelers
    : (value > kDailySpendMaxTravelers ? kDailySpendMaxTravelers : value);
