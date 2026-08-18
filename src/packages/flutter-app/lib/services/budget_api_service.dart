import 'dart:convert';
import '../models/budget.dart';
import '../models/daily_spend.dart';
import '../models/expense.dart';
import 'api_client.dart';

/// Wraps the per-trip budget & expense endpoints (`/trips/{id}/budget` and
/// `/trips/{id}/budget/expenses`). Mirrors [ChecklistApiService] conventions.
class BudgetApiService {
  final ApiClient apiClient;

  BudgetApiService(this.apiClient);

  List<Expense> _parseList(String body) {
    final list = jsonDecode(body) as List<dynamic>;
    return list
        .map((e) => Expense.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Budget> getBudget(String tripId) async {
    final res = await apiClient.httpClient.get(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) return Budget.fromJson(jsonDecode(res.body));
    throw Exception('Failed to load budget (${res.statusCode})');
  }

  /// Upsert the single per-trip target + currency (PUT). A null [targetAmount]
  /// clears the target (tracking spend only); [currency] defaults to USD.
  Future<Budget> upsertBudget(String tripId,
      {double? targetAmount, String currency = 'USD'}) async {
    final res = await apiClient.httpClient.put(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'target_amount': targetAmount, 'currency': currency}),
    );
    if (res.statusCode == 200) return Budget.fromJson(jsonDecode(res.body));
    throw Exception('Failed to save budget (${res.statusCode})');
  }

  Future<List<Expense>> listExpenses(String tripId) async {
    final res = await apiClient.httpClient.get(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget/expenses'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) return _parseList(res.body);
    throw Exception('Failed to load expenses (${res.statusCode})');
  }

  /// Adds an expense. [sourceKind]/[sourceId] (both or neither) link it to
  /// the booking row that spawned it — the server then treats the POST as an
  /// upsert-by-source (200 on a refresh/no-op, 201 on create) and marks the
  /// row auto. Throws [ApiException] so callers can tell the 422 per-trip
  /// cap apart from other failures.
  ///
  /// [planned] says which of the two columns [amount] is (00067). It defaults
  /// to **false — a payment** — which is what every pre-split caller meant, so
  /// the booked-flip prompt on the trip screen keeps both compiling and its
  /// semantics. A linked add must stay a payment: the server 400s a plan-only
  /// one rather than guessing.
  ///
  /// [legKey] files the line under one city leg (00070/00072) — the
  /// spend-per-city grouping. Mutually exclusive with [sourceKind]; the
  /// server 400s a request naming both, and 400s a key that is not one of
  /// the trip's current legs.
  ///
  /// [legPlan] marks the add as that city's PLAN SLOT (requires [legKey]) —
  /// the daily food & drink "Add to plan". It is what makes the POST an
  /// upsert-by-leg: a second tap returns the row that already exists (200)
  /// instead of filing a duplicate. An ordinary city-tagged add (the picker)
  /// leaves it false and always creates. Guarded `if (legPlan)` so a plain
  /// add's body stays byte-identical to before.
  Future<Expense> addExpense(String tripId,
      {required String category,
      required String label,
      required double amount,
      bool planned = false,
      String? sourceKind,
      String? sourceId,
      String? legKey,
      bool legPlan = false}) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget/expenses'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({
        'category': category,
        'label': label,
        if (planned) 'planned_amount': amount else 'actual_amount': amount,
        if (sourceKind != null) 'source_kind': sourceKind,
        if (sourceId != null) 'source_id': sourceId,
        if (legKey != null) 'leg_key': legKey,
        if (legPlan) 'leg_plan': true,
      }),
    );
    if (res.statusCode == 201 || res.statusCode == 200) {
      return Expense.fromJson(jsonDecode(res.body));
    }
    throw ApiException(
        statusCode: res.statusCode,
        message: res.body,
        endpoint: 'budget/expenses');
  }

  /// Records what a line actually cost. Omitting [amount] means "paid exactly
  /// what I planned" — the one-tap case; the server 409s when there is no plan
  /// to fall back on. Re-calling it edits what was paid.
  ///
  /// Paying is its own verb rather than a PATCH field because it is the only
  /// way to CLEAR the amount again, and a `null`-means-clear JSON convention
  /// would let a stale client un-pay every line it touched (00067).
  Future<Expense> purchaseExpense(String tripId, String expenseId,
      {double? amount}) async {
    final res = await apiClient.httpClient.post(
      Uri.parse(
          '${apiClient.baseUrl}/trips/$tripId/budget/expenses/$expenseId/purchase'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({if (amount != null) 'amount': amount}),
    );
    if (res.statusCode == 200) return Expense.fromJson(jsonDecode(res.body));
    throw ApiException(
        statusCode: res.statusCode,
        message: res.body,
        endpoint: 'budget/expenses/purchase');
  }

  /// "I haven't actually paid this." Clears what was paid and keeps the plan.
  /// The server 409s when the line has no plan — un-paying it would leave it
  /// with no amount at all, and deleting on the traveler's behalf is a guess.
  Future<Expense> unpurchaseExpense(String tripId, String expenseId) async {
    final res = await apiClient.httpClient.delete(
      Uri.parse(
          '${apiClient.baseUrl}/trips/$tripId/budget/expenses/$expenseId/purchase'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) return Expense.fromJson(jsonDecode(res.body));
    throw ApiException(
        statusCode: res.statusCode,
        message: res.body,
        endpoint: 'budget/expenses/purchase');
  }

  /// Partial update — pass only the fields to change (category / label /
  /// planned_amount / amount / position / leg_key). It cannot clear a plan:
  /// that is the 00067 contract, not an oversight.
  ///
  /// `'leg_key': 'Rome'` re-files the line under that city; `'leg_key': ''`
  /// clears the tag (empty-means-clear is the PATCH sentinel — a null decodes
  /// as "omitted, keep" like every other field). The server 409s a leg_key
  /// change on a plan-slot row ([Expense.legPlan]) — a plan's city is fixed.
  Future<Expense> updateExpense(
      String tripId, String expenseId, Map<String, dynamic> body) async {
    final res = await apiClient.httpClient.patch(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget/expenses/$expenseId'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode(body),
    );
    if (res.statusCode == 200) {
      return Expense.fromJson(jsonDecode(res.body));
    }
    throw Exception('Failed to update expense (${res.statusCode})');
  }

  /// The suggested per-person daily food & drink spend for each city on the
  /// trip (specs/daily-spend-guide). [tier] overrides the traveler's saved
  /// budget level for this read; omit it to let the server resolve one.
  ///
  /// Best-effort by design: the endpoint answers 200 with an empty city list
  /// and a reason code when it cannot produce an estimate, so the only throw
  /// here is a genuine transport/auth failure — which the provider then folds
  /// into an empty guide.
  Future<DailySpendGuide> getDailySpend(String tripId, {String? tier}) async {
    final uri = Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget/daily-spend')
        .replace(queryParameters: tier == null ? null : {'tier': tier});
    final res = await apiClient.httpClient.get(
      uri,
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode == 200) {
      return DailySpendGuide.fromJson(jsonDecode(res.body));
    }
    throw ApiException(
        statusCode: res.statusCode,
        message: res.body,
        endpoint: 'budget/daily-spend');
  }

  Future<void> deleteExpense(String tripId, String expenseId) async {
    final res = await apiClient.httpClient.delete(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget/expenses/$expenseId'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode != 204) {
      throw Exception('Failed to delete expense (${res.statusCode})');
    }
  }
}
