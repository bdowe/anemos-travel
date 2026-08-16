import 'dart:convert';
import '../models/budget.dart';
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
  Future<Expense> addExpense(String tripId,
      {required String category,
      required String label,
      required double amount,
      bool planned = false,
      String? sourceKind,
      String? sourceId}) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget/expenses'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({
        'category': category,
        'label': label,
        if (planned) 'planned_amount': amount else 'actual_amount': amount,
        if (sourceKind != null) 'source_kind': sourceKind,
        if (sourceId != null) 'source_id': sourceId,
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
  /// planned_amount / amount / position). It cannot clear a plan: that is the
  /// 00067 contract, not an oversight.
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
