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
  Future<Expense> addExpense(String tripId,
      {required String category,
      required String label,
      required double amount,
      String? sourceKind,
      String? sourceId}) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/budget/expenses'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({
        'category': category,
        'label': label,
        'amount': amount,
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

  /// Partial update — pass only the fields to change (category / label / amount
  /// / position).
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
