import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

// trips_api_service_patch_test.dart — the WIRE for PATCH /trips/{id}, which the
// widget tests cannot see: they drive a fake TripsApiService, so an omitted key
// or a dropped empty string would pass every one of them and fail against the
// real API. These pin the omitted-vs-empty distinction the trip description
// depends on (specs/trip-description) against patchTripHandler.

TripsApiService _service(MockClient client) =>
    TripsApiService(ApiClient(baseUrl: 'http://test/api/v1', client: client));

String _tripJson({String? summary}) => jsonEncode({
      'id': 't1',
      'title': 'Sicily Loop',
      if (summary != null) 'summary': summary,
      'created_at': '2026-08-01',
      'updated_at': '2026-08-01',
    });

Future<Map<String, dynamic>> _capture(
  Future<void> Function(TripsApiService) call, {
  String? responseSummary,
}) async {
  late http.Request captured;
  final service = _service(MockClient((request) async {
    captured = request;
    return http.Response(_tripJson(summary: responseSummary), 200,
        headers: {'content-type': 'application/json'});
  }));
  await call(service);
  return jsonDecode(captured.body) as Map<String, dynamic>;
}

void main() {
  test('an omitted summary sends no summary key at all', () async {
    final body = await _capture(
      (s) => s.patchTrip('t1', title: 'Sicily Loop'),
      responseSummary: 'Untouched.',
    );
    expect(body, {'title': 'Sicily Loop'});
    // Not `'summary': null` — the server reads a present-but-null key as an
    // explicit value and would clear the description.
    expect(body.containsKey('summary'), isFalse);
  });

  test('an empty summary IS sent, because that is how a description clears',
      () async {
    final body = await _capture((s) => s.patchTrip('t1', summary: ''));
    // The distinction UpdateTrip's COALESCE set could not express, and the whole
    // reason the server routes summary through applyTripSummary instead.
    expect(body, {'summary': ''});
  });

  test('a name and a description ride one request', () async {
    final body = await _capture(
      (s) => s.patchTrip('t1', title: 'Sicily Loop', summary: 'Ten days.'),
      responseSummary: 'Ten days.',
    );
    expect(body, {'title': 'Sicily Loop', 'summary': 'Ten days.'});
  });

  test('the parsed trip carries the description back', () async {
    final service = _service(MockClient((_) async => http.Response(
        _tripJson(summary: 'Ten days circling Sicily.'), 200,
        headers: {'content-type': 'application/json'})));
    final trip = await service.patchTrip('t1', summary: 'Ten days circling Sicily.');
    expect(trip.summary, 'Ten days circling Sicily.');
  });

  test('a cleared description comes back absent, not empty', () async {
    // TripResponse.Summary is `omitempty`, so a cleared description simply is
    // not in the payload — the screen has to read that as "no description".
    final service = _service(MockClient((_) async => http.Response(
        _tripJson(), 200, headers: {'content-type': 'application/json'})));
    final trip = await service.patchTrip('t1', summary: '');
    expect(trip.summary, isNull);
  });
}
