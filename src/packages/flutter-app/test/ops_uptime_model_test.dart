import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/ops_uptime.dart';

// Wire-contract parity for GET /admin/ops/uptime (specs/uptime-history plan's
// Contract Parity table, exercised): the documented payload parses verbatim,
// and the null-vs-zero distinction the whole feature hangs on survives a
// round trip.

void main() {
  test('parses the documented payload verbatim', () {
    final json = {
      'days': 90,
      'start_day': '2026-05-16',
      'monitoring_since': '2026-08-14T02:10:00Z',
      'components': [
        {
          'key': 'api',
          'status': 'up',
          'uptime_pct': 99.94,
          'observed_days': 31,
          'days': [
            {
              'day': '2026-05-16',
              'state': 'no_data',
              'uptime_pct': null,
              'up_s': 0,
              'down_s': 0,
              'unknown_s': 86400,
              'reason_codes': <String>[],
            },
            {
              'day': '2026-08-13',
              'state': 'degraded',
              'uptime_pct': 99.31,
              'up_s': 85800,
              'down_s': 600,
              'unknown_s': 0,
              'reason_codes': ['process_down'],
            },
          ],
        },
      ],
    };

    final u = OpsUptime.fromJson(json);
    expect(u.days, 90);
    expect(u.startDay, '2026-05-16');
    expect(u.monitoringSince, DateTime.utc(2026, 8, 14, 2, 10));
    expect(u.components, hasLength(1));

    final api = u.components.first;
    expect(api.key, 'api');
    expect(api.uptimePct, 99.94);
    expect(api.observedDays, 31);

    final noData = api.days[0];
    expect(noData.state, 'no_data');
    expect(noData.uptimePct, isNull); // null, NOT 0 — the load-bearing bit
    expect(noData.hasData, isFalse);
    expect(noData.unknownS, 86400);

    final degraded = api.days[1];
    expect(degraded.hasData, isTrue);
    expect(degraded.uptimePct, 99.31);
    expect(degraded.reasonCodes, ['process_down']);
  });

  test('an int percentage still parses (Go marshals 100 as 100, not 100.0)',
      () {
    final d = UptimeDay.fromJson({
      'day': '2026-08-13',
      'state': 'up',
      'uptime_pct': 100, // int on the wire
      'up_s': 86400,
      'down_s': 0,
      'unknown_s': 0,
      'reason_codes': <String>[],
    });
    expect(d.uptimePct, 100.0);
  });

  test('unknown states and reason codes parse rather than throw', () {
    final d = UptimeDay.fromJson({
      'day': '2026-08-13',
      'state': 'partially_cloudy', // a state the server adds tomorrow
      'uptime_pct': 50.0,
      'up_s': 1,
      'down_s': 1,
      'unknown_s': 0,
      'reason_codes': ['solar_flare'],
    });
    expect(d.state, 'partially_cloudy');
    expect(d.hasData, isTrue);
  });

  test('utcDay parses bare dates as UTC midnight and rejects junk', () {
    expect(OpsUptime.utcDay('2026-05-16'), DateTime.utc(2026, 5, 16));
    expect(OpsUptime.utcDay('2026-05-16')!.isUtc, isTrue);
    expect(OpsUptime.utcDay('not-a-date'), isNull);
  });

  test('const default is an honest empty', () {
    const u = OpsUptime();
    expect(u.components, isEmpty);
    expect(u.monitoringSince, isNull);
  });
}
