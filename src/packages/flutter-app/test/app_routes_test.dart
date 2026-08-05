import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/app_routes.dart';

/// The URL grammar must round-trip: every location the write half can emit
/// parses back to the target that reproduces the same screen (and the same
/// location string), so the two halves of URL persistence cannot drift.
void main() {
  BootTarget? parse(String location) => parseBootTarget(Uri.parse(location));

  test('tab roots round-trip', () {
    expect(parse(kHomeLocation), const BootTarget(AppTab.home));
    expect(parse(kPlanLocation), const BootTarget(AppTab.plan));
    expect(parse(kTripsLocation), const BootTarget(AppTab.trips));
  });

  test('trip detail round-trips and /trip aliases to it', () {
    const target = BootTarget(AppTab.trips, tripId: 'abc-123');
    expect(parse(tripDetailLocation('abc-123')), target);
    expect(parse('/trip/abc-123'), target);
  });

  test('plan chat round-trips', () {
    expect(parse(planChatLocation('chat-xyz')),
        const BootTarget(AppTab.plan, chatId: 'chat-xyz'));
  });

  test('every utility screen round-trips onto its restore tab', () {
    for (final utility in BootUtility.values) {
      expect(parse(utilityLocation(utility)),
          BootTarget(utilityTab(utility), utility: utility),
          reason: utility.name);
    }
  });

  test('trailing slashes and query strings are tolerated', () {
    expect(parse('/trips/'), const BootTarget(AppTab.trips));
    expect(parse('/trips/abc/'), const BootTarget(AppTab.trips, tripId: 'abc'));
    expect(parse('/plan?foo=1'), const BootTarget(AppTab.plan));
  });

  test('unknown and over-long paths parse to null (plain catch-all)', () {
    for (final path in [
      '/nope',
      '/trips/a/b',
      '/plan/a/b',
      '/admin',
      '/admin/nope',
      '/trip',
      // Token routes are matched before the grammar in generateRoute, but the
      // grammar itself must not claim them either.
      '/share/tok',
      '/sso/code',
    ]) {
      expect(parse(path), isNull, reason: path);
    }
  });
}
