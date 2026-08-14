import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/services/pending_connect.dart';

/// The consent request has to outlive a sign-in round trip that replaces the
/// whole page (SSO), but must never redirect an unrelated sign-in later on
/// (specs/mcp-connector).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = PendingConnectStore();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nothing pending yields null', () async {
    expect(await store.take(), isNull);
  });

  test('a saved request comes back once, then is forgotten', () async {
    await store.save('gt_rq_abc');
    expect(await store.take(), 'gt_rq_abc');
    // Single use: a completed link must not replay on the next sign-in.
    expect(await store.take(), isNull);
  });

  test('clear drops a pending request', () async {
    await store.save('gt_rq_abc');
    await store.clear();
    expect(await store.take(), isNull);
  });

  test('a stale record is ignored', () async {
    final tooOld = DateTime.now()
        .toUtc()
        .subtract(PendingConnectStore.maxAge + const Duration(minutes: 1))
        .millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'pending_connect.request_token': 'gt_rq_old',
      'pending_connect.saved_at': tooOld,
    });
    expect(await store.take(), isNull);
  });

  test('a record without a timestamp is ignored', () async {
    SharedPreferences.setMockInitialValues({
      'pending_connect.request_token': 'gt_rq_orphan',
    });
    expect(await store.take(), isNull);
  });
}
