import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/budget.dart';
import '../models/daily_spend.dart';
import '../models/expense.dart';
import '../services/budget_api_service.dart';
import '../utils/daily_spend.dart';
import 'api_client_provider.dart';

final budgetApiServiceProvider = Provider<BudgetApiService>((ref) {
  return BudgetApiService(ref.watch(apiClientProvider));
});

/// A trip's budget (target + currency + derived spent/remaining), keyed by trip
/// id. Mutations invalidate this provider to refetch. `.when(skipLoadingOnReload)`
/// (the default) keeps the current values on screen during the refresh.
final budgetProvider =
    FutureProvider.family<Budget, String>((ref, tripId) async {
  return ref.watch(budgetApiServiceProvider).getBudget(tripId);
});

/// A trip's expense line-items, keyed by trip id. Invalidated alongside
/// [budgetProvider] on every mutation.
final expensesProvider =
    FutureProvider.family<List<Expense>, String>((ref, tripId) async {
  return ref.watch(budgetApiServiceProvider).listExpenses(tripId);
});

/// What the traveler has typed into the Budget tab's add-expense row and not
/// saved yet.
///
/// It lives here rather than in `BudgetSection`'s State because that widget is
/// torn down constantly, and none of the reasons are the traveler's doing:
/// it is a conditional sliver, so switching to Itinerary or Bookings unmounts
/// it, and opening or closing the refine chat panel re-parents the whole trip
/// body and disposes everything beneath it. Pricing a flight means doing one
/// of those — "Find flights" lives on the booking rows, and the chat is the
/// other place to ask — so the row was reliably empty on the way back.
///
/// In-memory and keyed by trip, deliberately: it survives every in-app hop,
/// and a page reload starts clean. Same lifetime rationale as
/// `tripRefineProvider` (plan_provider.dart), which keeps a panel conversation
/// alive across that same remount.
@immutable
class ExpenseDraft {
  /// Empty strings, not nulls: these mirror two `TextField`s, whose empty
  /// state IS the empty string.
  final String label;

  /// The literal contents of the amount field — including a half-typed
  /// `"412."`. Never a parsed number: parsing belongs to the one place that
  /// submits, and [Expense.amount] is the `double` this is not.
  final String amountText;

  /// A canonical API category value (`kExpenseCategories`), never a localized
  /// label. `general` is the server's default and the row's opening pick.
  final String category;

  /// Whether the row will add a PLAN or a PAYMENT (00067).
  ///
  /// Defaults to planned, and lives here for the same reason [category] does:
  /// it is a *choice*, and resetting it on the next remount would silently
  /// re-file the following expense. Planned is the safer default because the
  /// two mistakes are not symmetric — a wrongly-planned row is visible (it
  /// shows a hollow mark and "Total spent" doesn't move) and is two taps to
  /// fix, while a wrongly-paid one inflates spend quietly and can fire a false
  /// over-budget warning.
  final bool planned;

  /// The city leg the next add will be filed under (00072), or null for "no
  /// city". A canonical `RenderLeg.Key` (`Rome`, `Rome#2`), never a localized
  /// label — the same spelling [Expense.legKey] carries.
  final String? legKey;

  const ExpenseDraft({
    this.label = '',
    this.amountText = '',
    this.category = 'general',
    this.planned = true,
    this.legKey,
  });

  ExpenseDraft copyWith({
    String? label,
    String? amountText,
    String? category,
    bool? planned,
    String? legKey,
    bool clearLegKey = false,
  }) =>
      ExpenseDraft(
        label: label ?? this.label,
        amountText: amountText ?? this.amountText,
        category: category ?? this.category,
        planned: planned ?? this.planned,
        legKey: clearLegKey ? null : (legKey ?? this.legKey),
      );
}

class ExpenseDraftNotifier extends StateNotifier<ExpenseDraft> {
  ExpenseDraftNotifier() : super(const ExpenseDraft());

  /// Both fields together, because the row's two controllers share one
  /// listener — whichever fires, the draft records what is on screen.
  void setText({required String label, required String amountText}) {
    if (label == state.label && amountText == state.amountText) return;
    state = state.copyWith(label: label, amountText: amountText);
  }

  void setCategory(String category) {
    if (category == state.category) return;
    state = state.copyWith(category: category);
  }

  void setPlanned(bool planned) {
    if (planned == state.planned) return;
    state = state.copyWith(planned: planned);
  }

  /// null = "no city". Empty string is not a value here — the wire's
  /// ''-clears sentinel belongs to the PATCH path, not the draft.
  void setLegKey(String? legKey) {
    if (legKey == state.legKey) return;
    state = state.copyWith(legKey: legKey, clearLegKey: legKey == null);
  }

  /// After a successful save. Deliberately keeps the category, the
  /// planned/paid pick AND the city: all three are choices, and a traveler
  /// entering eight estimates before a trip — or logging five dinners in
  /// Rome — should state each once, not once per line.
  void clearText() => setText(label: '', amountText: '');
}

final expenseDraftProvider =
    StateNotifierProvider.family<ExpenseDraftNotifier, ExpenseDraft, String>(
        (ref, tripId) => ExpenseDraftNotifier());

/// How the Budget tab's receipt is grouped: by expense category (the
/// original view) or by city leg (spend-per-city, 00072). Neither mode hides
/// a line — every expense appears in exactly one group either way.
///
/// Session-local and keyed by trip, the [DailySpendSettings] lifetime and
/// rationale: this is a way of *looking* at the receipt, not a property of
/// the trip, so it survives the constant remounts (tab switches, the chat
/// panel re-parenting the body) and a page reload starting on Category is
/// correct.
enum BudgetGrouping { category, city }

final budgetGroupingProvider = StateProvider.family<BudgetGrouping, String>(
    (ref, tripId) => BudgetGrouping.category);

// --- daily food & drink suggestion (specs/daily-spend-guide) ----------------

/// Identifies one daily-spend read. The tier is part of the key because prices
/// genuinely vary by it — a luxury answer must not be served from the mid
/// fetch. Value equality by hand, the [WeatherQuery] convention: without it
/// every rebuild is a new family key and refetches.
@immutable
class DailySpendQuery {
  final String tripId;

  /// null means "resolve it for me" — the server then uses the traveler's
  /// saved budget level, or its default, and says which in `tier_source`.
  final String? tier;

  const DailySpendQuery({required this.tripId, this.tier});

  @override
  bool operator ==(Object other) =>
      other is DailySpendQuery && other.tripId == tripId && other.tier == tier;

  @override
  int get hashCode => Object.hash(tripId, tier);
}

/// The per-city daily food & drink suggestion. **Best-effort**, exactly like
/// [weatherByCityProvider]: any failure resolves to an empty guide rather than
/// an error state, because a suggestion the Budget tab could not fetch is a
/// section that shouldn't appear — never a red box over the traveler's money.
final dailySpendProvider =
    FutureProvider.family<DailySpendGuide, DailySpendQuery>((ref, query) async {
  try {
    return await ref
        .watch(budgetApiServiceProvider)
        .getDailySpend(query.tripId, tier: query.tier);
  } catch (_) {
    return const DailySpendGuide(cities: []);
  }
});

/// What the traveler has set on the daily-spend section: which tier to price
/// at, and how many people are eating.
///
/// Session-local and keyed by trip, the same lifetime and rationale as
/// [ExpenseDraft] — the section is unmounted on every tab switch and every
/// chat-panel toggle. Deliberately NOT persisted: [tier] is a look at a
/// different price level, not a change to the traveler's saved budget level,
/// and [travelers] is a property of this trip that the trip does not store.
@immutable
class DailySpendSettings {
  /// null = let the server resolve the tier from the saved profile.
  final String? tier;
  final int travelers;

  const DailySpendSettings({this.tier, this.travelers = 1});

  DailySpendSettings copyWith({String? tier, int? travelers}) =>
      DailySpendSettings(
        tier: tier ?? this.tier,
        travelers: travelers ?? this.travelers,
      );
}

class DailySpendSettingsNotifier extends StateNotifier<DailySpendSettings> {
  DailySpendSettingsNotifier() : super(const DailySpendSettings());

  void setTier(String tier) {
    if (tier == state.tier) return;
    state = state.copyWith(tier: tier);
  }

  void setTravelers(int travelers) {
    final next = clampTravelers(travelers);
    if (next == state.travelers) return;
    state = state.copyWith(travelers: next);
  }
}

final dailySpendSettingsProvider = StateNotifierProvider.family<
    DailySpendSettingsNotifier,
    DailySpendSettings,
    String>((ref, tripId) => DailySpendSettingsNotifier());
