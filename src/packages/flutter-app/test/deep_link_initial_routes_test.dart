import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/main.dart';

/// A deep link must boot on exactly one route. The framework default expands
/// `/share/x` into a stack of every path prefix; the prefixes hit the
/// AuthGate catch-all and a signed-in session then mounts two AppShells whose
/// tab navigators collide on the same GlobalKeys (blank-screen tree
/// corruption). Regression test for generateInitialRoutes.
void main() {
  test('deep links generate a single initial route', () {
    for (final path in [
      '/',
      '/share/tok123',
      '/invite/tok123',
      '/reset/tok123',
      '/verify/tok123',
      '/sso/code123',
      '/connect/tok123',
      // URL persistence boot paths (specs/url-page-persistence) ride the same
      // one-route invariant: each lands on a single AuthGate that restores
      // the page inside the shell.
      '/plan',
      '/plan/chat-abc',
      '/trips',
      '/trips/t1',
      '/trip/t1',
      '/preferences',
      '/account',
      '/admin/metrics',
      '/admin/local',
      '/import',
      '/guides',
      '/notifications',
      '/no-such-page',
    ]) {
      final routes = generateInitialRoutes(path);
      expect(routes, hasLength(1), reason: 'path $path');
      expect(routes.single.settings.name, path);
    }
  });
}
