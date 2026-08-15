import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/budget.dart';
import '../models/expense.dart';
import '../services/budget_api_service.dart';
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

  const ExpenseDraft({
    this.label = '',
    this.amountText = '',
    this.category = 'general',
  });

  ExpenseDraft copyWith({String? label, String? amountText, String? category}) =>
      ExpenseDraft(
        label: label ?? this.label,
        amountText: amountText ?? this.amountText,
        category: category ?? this.category,
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

  /// After a successful save. Deliberately keeps the category: the row already
  /// behaves that way within a session, and consecutive expenses tend to share
  /// one.
  void clearText() => setText(label: '', amountText: '');
}

final expenseDraftProvider =
    StateNotifierProvider.family<ExpenseDraftNotifier, ExpenseDraft, String>(
        (ref, tripId) => ExpenseDraftNotifier());
