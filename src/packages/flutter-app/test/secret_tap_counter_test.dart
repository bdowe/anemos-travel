import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/utils/secret_tap_counter.dart';

/// Timing rules for the touch way into the easter egg. Pure, so the gaps are
/// stated rather than raced.
void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);

  /// Taps at the given offsets from [t0] (in ms); returns the offsets that
  /// fired.
  List<int> firesAt(List<int> offsetsMs) {
    final counter = SecretTapCounter();
    return [
      for (final ms in offsetsMs)
        if (counter.tap(t0.add(Duration(milliseconds: ms)))) ms,
    ];
  }

  /// n taps 100 ms apart starting at [from].
  List<int> burst(int n, {int from = 0}) =>
      [for (var i = 0; i < n; i++) from + i * 100];

  /// The first offset that is definitely a NEW run — one millisecond past the
  /// window measured from [lastTapAt], not from t0. Getting that reference
  /// point wrong is the easy mistake: the window is a gap between two taps.
  int afterPause(int lastTapAt) =>
      lastTapAt + kSecretTapWindow.inMilliseconds + 1;

  test('a human cadence fires — stated in milliseconds, not in the constant',
      () {
    // Every other test in this file is expressed in terms of
    // kSecretTapWindow, so all of them stay green no matter how small it gets.
    // That is exactly how a 700 ms window shipped and turned out to be
    // unusable by hand: it was verified only by automation tapping every
    // 145 ms, and a person tapping about once a second could never trigger it.
    // This test states the human requirement in absolute time, so shrinking
    // the window has to fail something.
    for (final cadence in [500, 1000, 1500, 1800]) {
      expect(
        firesAt([for (var i = 0; i < kSecretTapCount; i++) i * cadence]),
        isNotEmpty,
        reason: 'a tap every ${cadence}ms must reach the egg',
      );
    }
    // Still not something ordinary navigation can stumble into.
    expect(
      firesAt([for (var i = 0; i < kSecretTapCount; i++) i * 3000]),
      isEmpty,
    );
  });

  test('the seventh rapid tap fires, and not the sixth', () {
    expect(firesAt(burst(kSecretTapCount)), [(kSecretTapCount - 1) * 100]);
    expect(firesAt(burst(kSecretTapCount - 1)), isEmpty);
  });

  test('a gap longer than the window restarts the count', () {
    // Six taps, a pause, then five more: eleven taps, no fire — the pause
    // means the second run is only five long.
    final resume = afterPause(500);
    expect(firesAt([...burst(6), ...burst(5, from: resume)]), isEmpty);
  });

  test('the slow tap begins the new run rather than being discarded', () {
    // One stray tap, a long pause, then seven more. The stray must not cost
    // the user a tap: the pause-crossing tap is number one of the new run.
    final resume = afterPause(0);
    expect(
      firesAt([0, ...burst(kSecretTapCount, from: resume)]),
      [resume + (kSecretTapCount - 1) * 100],
    );
  });

  test('the window is measured between consecutive taps, not across the run',
      () {
    // Every gap is just inside the window, so a run far longer than the
    // window still counts.
    final gap = kSecretTapWindow.inMilliseconds;
    final offsets = [for (var i = 0; i < kSecretTapCount; i++) i * gap];
    expect(firesAt(offsets), [offsets.last]);
  });

  test('one tap over the window does not fire, but the next run can', () {
    final gap = kSecretTapWindow.inMilliseconds + 1;
    expect(firesAt([for (var i = 0; i < 20; i++) i * gap]), isEmpty);
  });

  test('firing resets, so an eighth tap does not fire again', () {
    expect(firesAt(burst(kSecretTapCount + 1)), [(kSecretTapCount - 1) * 100]);
  });

  test('a second full burst fires again', () {
    expect(
      firesAt([...burst(kSecretTapCount), ...burst(kSecretTapCount, from: 2000)]),
      [(kSecretTapCount - 1) * 100, 2000 + (kSecretTapCount - 1) * 100],
    );
  });
}
