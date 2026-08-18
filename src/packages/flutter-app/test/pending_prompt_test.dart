import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/services/pending_prompt.dart';

/// The landing prompt has to outlive a sign-in round trip that replaces the
/// whole page (SSO), but must never seed an unrelated sign-in later on
/// (specs/landing-prompt-handoff). Structure mirrors pending_connect_test.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = PendingPromptStore();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PendingPromptStore.resetMemoryForTest();
  });

  test('nothing pending yields null', () async {
    expect(await store.take(), isNull);
  });

  test('a saved prompt comes back once — trimmed, with its source — then '
      'is forgotten', () async {
    await store.save('  A week in Rome  ', sourceId: 'rome');
    final taken = await store.take();
    expect(taken?.text, 'A week in Rome');
    expect(taken?.sourceId, 'rome');
    // Single use: a consumed prompt must not replay on the next sign-in.
    expect(await store.take(), isNull);
  });

  test('a typed prompt carries no source id', () async {
    await store.save('Tapas crawl in San Sebastián');
    expect((await store.take())?.sourceId, isNull);
  });

  test('empty and whitespace-only text is not stored', () async {
    await store.save('   ');
    expect(await store.take(), isNull);
  });

  test('text is capped at maxPromptLength', () async {
    await store.save('x' * (PendingPromptStore.maxPromptLength + 500));
    expect(
        (await store.take())?.text.length, PendingPromptStore.maxPromptLength);
  });

  test('a second save overwrites the first — one slot, last write wins',
      () async {
    await store.save('first idea', sourceId: 'paris');
    await store.save('second idea');
    final taken = await store.take();
    expect(taken?.text, 'second idea');
    expect(taken?.sourceId, isNull);
    expect(await store.take(), isNull);
  });

  test('clear drops a pending prompt', () async {
    await store.save('A week in Rome');
    await store.clear();
    expect(await store.take(), isNull);
  });

  test('a stale stored record is ignored', () async {
    final tooOld = DateTime.now()
        .toUtc()
        .subtract(PendingPromptStore.maxAge + const Duration(minutes: 1))
        .millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'pending_prompt.text': 'A week in Rome',
      'pending_prompt.saved_at': tooOld,
    });
    expect(await store.take(), isNull);
  });

  test('a record without a timestamp is ignored', () async {
    SharedPreferences.setMockInitialValues({
      'pending_prompt.text': 'orphan',
    });
    expect(await store.take(), isNull);
  });

  test('the memory mirror survives a wiped preference store (private '
      'browsing on the same-page email path)', () async {
    await store.save('A week in Rome', sourceId: 'rome');
    // Simulate storage that never accepted the write.
    SharedPreferences.setMockInitialValues({});
    final taken = await store.take();
    expect(taken?.text, 'A week in Rome');
    expect(taken?.sourceId, 'rome');
    expect(await store.take(), isNull);
  });
}
