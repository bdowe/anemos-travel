import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';

/// ApiClient.send: the shared boot-critical request path (timeout + bounded
/// retry). The retry matrix is a contract — 429/503 retry any method (this
/// API emits them only pre-handler), 502/transport retry GETs only, and an
/// exhausted transport failure rethrows the ORIGINAL exception so
/// TripCache.isNetworkError keeps classifying on the concrete type.
void main() {
  ApiClient client(Future<http.Response> Function(http.Request) handler) =>
      ApiClient(baseUrl: 'http://test/api/v1', client: MockClient(handler));

  test('429 with Retry-After: 0 retries (any method) and then succeeds',
      () async {
    var calls = 0;
    final api = client((req) async {
      calls++;
      if (calls == 1) {
        return http.Response('rate limited', 429,
            headers: {'retry-after': '0'});
      }
      return http.Response('{"ok":true}', 200);
    });

    final res = await api.send('POST', '/plan-adjacent', jsonBody: {'a': 1});
    expect(res.statusCode, 200);
    expect(calls, 2);
  });

  test('GET 502 retries and succeeds', () async {
    var calls = 0;
    final api = client((req) async {
      calls++;
      return calls == 1
          ? http.Response('bad gateway', 502)
          : http.Response('{}', 200);
    });

    final res = await api.send('GET', '/trips/t1');
    expect(res.statusCode, 200);
    expect(calls, 2);
  });

  test('POST 502 throws immediately — no retry for non-GET on 502', () async {
    var calls = 0;
    final api = client((req) async {
      calls++;
      return http.Response('bad gateway', 502);
    });

    await expectLater(
      api.send('POST', '/trips', jsonBody: {'title': 'x'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 502)),
    );
    expect(calls, 1);
  });

  test('stable statuses (404) fail on the first attempt with the status',
      () async {
    var calls = 0;
    final api = client((req) async {
      calls++;
      return http.Response('not found', 404);
    });

    await expectLater(
      api.send('GET', '/trips/gone'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.endpoint, 'endpoint', '/trips/gone')),
    );
    expect(calls, 1);
  });

  test('exhausted attempts on 429 surface an ApiException(429)', () async {
    var calls = 0;
    final api = client((req) async {
      calls++;
      return http.Response('rate limited', 429, headers: {'retry-after': '0'});
    });

    await expectLater(
      api.send('GET', '/trips/t1', attempts: 2),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 429)),
    );
    expect(calls, 2);
  });

  test(
      'an exhausted transport failure rethrows the original ClientException '
      'and still classifies as a network error for the trip cache', () async {
    var calls = 0;
    final api = client((req) async {
      calls++;
      throw http.ClientException('connection refused');
    });

    Object? caught;
    try {
      // attempts: 1 keeps the test instant (no backoff sleeps).
      await api.send('GET', '/trips/t1', attempts: 1);
    } catch (e) {
      caught = e;
    }
    expect(calls, 1);
    expect(caught, isA<http.ClientException>(),
        reason: 'must rethrow unwrapped, never wrap in ApiException');
    expect(TripCache.isNetworkError(caught!), isTrue);
  });

  test('POST transport failure never retries (handler may have run)',
      () async {
    var calls = 0;
    final api = client((req) async {
      calls++;
      throw http.ClientException('reset');
    });

    await expectLater(api.send('POST', '/trips', jsonBody: {}),
        throwsA(isA<http.ClientException>()));
    expect(calls, 1);
  });

  test('query parameters and JSON body are applied', () async {
    late http.Request seen;
    final api = client((req) async {
      seen = req;
      return http.Response('{}', 200);
    });

    await api.send('GET', '/flights/airports', query: {'q': 'LAX'});
    expect(seen.url.toString(), 'http://test/api/v1/flights/airports?q=LAX');

    await api.send('POST', '/x', jsonBody: {'k': 'v'});
    expect(seen.body, '{"k":"v"}');
    expect(seen.headers['Content-Type'], startsWith('application/json'));
  });

  test('isTransientError matches transient shapes only', () {
    ApiException ex(int s) =>
        ApiException(statusCode: s, message: '', endpoint: 'x');
    expect(isTransientError(http.ClientException('x')), isTrue);
    for (final s in [0, 429, 502, 503, 504]) {
      expect(isTransientError(ex(s)), isTrue, reason: '$s is transient');
    }
    for (final s in [400, 401, 403, 404, 422, 500]) {
      expect(isTransientError(ex(s)), isFalse, reason: '$s is stable');
    }
    expect(isTransientError(Exception('Failed to load trip (429)')), isFalse,
        reason: 'untyped exceptions never match');
  });
}
