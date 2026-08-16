import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/budget_api_service.dart';

// budget_api_service_test.dart — the WIRE, which the widget tests cannot see:
// they drive a fake service, so a wrong field name or path would pass every
// one of them and fail against the real API. These pin the four request shapes
// the planned/paid split added (00067) against budget_handler.go.

BudgetApiService _service(MockClient client) =>
    BudgetApiService(ApiClient(baseUrl: 'http://test/api/v1', client: client));

/// The server's expense shape, minus whatever a case wants to override.
String _expenseJson({
  double? planned,
  double? actual,
  bool purchased = false,
}) =>
    jsonEncode({
      'id': 'e1',
      'category': 'flights',
      'label': 'Flights',
      'amount': actual ?? planned ?? 0,
      'planned_amount': planned,
      'actual_amount': actual,
      'purchased': purchased,
      'position': 0,
      'auto': false,
      'source_kind': null,
      'source_id': null,
    });

void main() {
  test('adding a planned expense sends planned_amount, never amount', () async {
    late http.Request captured;
    final service = _service(MockClient((request) async {
      captured = request;
      return http.Response(_expenseJson(planned: 400), 201,
          headers: {'content-type': 'application/json'});
    }));

    final expense = await service.addExpense('t1',
        category: 'flights', label: 'Flights', amount: 400, planned: true);

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/trips/t1/budget/expenses');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['planned_amount'], 400);
    expect(body.containsKey('actual_amount'), isFalse);
    // The legacy field must NOT ride along: the server ignores it when an
    // explicit one is present, but sending both invites the two to disagree.
    expect(body.containsKey('amount'), isFalse);
    expect(expense.plannedFor, 400);
    expect(expense.paidAmount, isNull);
  });

  test('the default add is a PAYMENT — what every pre-split caller meant',
      () async {
    late http.Request captured;
    final service = _service(MockClient((request) async {
      captured = request;
      return http.Response(_expenseJson(actual: 150, purchased: true), 201,
          headers: {'content-type': 'application/json'});
    }));

    // Exactly the call the trip screen's booked-flip prompt makes.
    await service.addExpense('t1',
        category: 'lodging',
        label: 'Hotel',
        amount: 150,
        sourceKind: 'accommodation',
        sourceId: 'acc1');

    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['actual_amount'], 150);
    expect(body.containsKey('planned_amount'), isFalse);
    expect(body['source_kind'], 'accommodation');
  });

  test('paying posts the price to the purchase verb', () async {
    late http.Request captured;
    final service = _service(MockClient((request) async {
      captured = request;
      return http.Response(_expenseJson(planned: 400, actual: 372, purchased: true), 200,
          headers: {'content-type': 'application/json'});
    }));

    final expense =
        await service.purchaseExpense('t1', 'e1', amount: 372);

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/trips/t1/budget/expenses/e1/purchase');
    expect(jsonDecode(captured.body), {'amount': 372});
    // The plan came back intact — the whole point of the verb.
    expect(expense.plannedFor, 400);
    expect(expense.paidAmount, 372);
    expect(expense.showsPair, isTrue);
  });

  test('paying with no amount sends an empty body, meaning "at the plan"',
      () async {
    late http.Request captured;
    final service = _service(MockClient((request) async {
      captured = request;
      return http.Response(_expenseJson(planned: 42, actual: 42, purchased: true), 200,
          headers: {'content-type': 'application/json'});
    }));

    await service.purchaseExpense('t1', 'e1');

    expect(jsonDecode(captured.body), isEmpty,
        reason: 'an absent amount is what the server reads as "the plan"');
  });

  test('un-paying DELETEs the same path and keeps the plan', () async {
    late http.Request captured;
    final service = _service(MockClient((request) async {
      captured = request;
      return http.Response(_expenseJson(planned: 400), 200,
          headers: {'content-type': 'application/json'});
    }));

    final expense = await service.unpurchaseExpense('t1', 'e1');

    expect(captured.method, 'DELETE');
    expect(captured.url.path, '/api/v1/trips/t1/budget/expenses/e1/purchase');
    expect(expense.paidAmount, isNull);
    expect(expense.plannedFor, 400);
  });

  test('a 409 surfaces as ApiException so the caller can tell it apart',
      () async {
    final service = _service(MockClient((request) async => http.Response(
        jsonEncode({'message': 'this expense has no planned amount'}), 409)));

    await expectLater(
      service.unpurchaseExpense('t1', 'e1'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 409)),
    );
  });

  test('the budget response carries all four totals', () async {
    final service = _service(MockClient((request) async => http.Response(
        jsonEncode({
          'target_amount': 2000,
          'currency': 'USD',
          'spent': 378,
          'remaining': 1622,
          'planned': 1150,
          'projected': 1128,
          'plan_variance': -28,
        }),
        200,
        headers: {'content-type': 'application/json'})));

    final budget = await service.getBudget('t1');

    expect(budget.spent, 378);
    expect(budget.planned, 1150);
    expect(budget.projected, 1128);
    expect(budget.planVariance, -28);
  });

  test('a server that predates the split leaves the new totals null', () async {
    final service = _service(MockClient((request) async => http.Response(
        jsonEncode({
          'target_amount': 2000,
          'currency': 'USD',
          'spent': 378,
          'remaining': 1622,
        }),
        200,
        headers: {'content-type': 'application/json'})));

    final budget = await service.getBudget('t1');

    // null means unknown, never 0 — the tab renders its pre-split self.
    expect(budget.planned, isNull);
    expect(budget.projected, isNull);
    expect(budget.planVariance, isNull);
  });
}
